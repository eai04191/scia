import os
import SafariServices
import SciaCore
import UIKit

/// ログイン中のアカウントの画面一式。タブの組み立てと、各タブの読み込みと接続の寿命をまとめる。
@MainActor
final class SessionController {
    let rootViewController: UIViewController
    /// このセッションで使っているアカウント。
    let credential: Credential
    private let home: HomeTimelineController
    private let notifications: NotificationsController
    /// ホームと通知で共有する、ストリーミングの接続。
    private let streamingHub: StreamingHub
    private let client: MastodonClient
    /// 429や503で止められたときに、自動の通信を控える。このセッションの通信で共有する。
    private let rateLimit = RateLimitGate()
    /// 使えないと分かった機能を、このセッションの間だけ止める。次の起動では作り直し、もう一度試す。
    private let features = FeatureAvailability()
    /// 失敗の記録。デバッグ版でだけ応答の本文も残す。
    #if DEBUG
    private let requestLog = RequestLog(includesBody: true)
    #else
    private let requestLog = RequestLog(includesBody: false)
    #endif
    /// 「接続の状態」画面に出す、このセッションの接続の状態。
    let diagnostics: ConnectionDiagnostics
    /// 電波が戻ったときと、レート制限が明けたときに、読み込みをやり直す。
    private var recoveryTasks: [Task<Void, Never>] = []
    private let interactions: StatusInteractions
    /// カードが付く前に受け取った投稿を、見えている間に取り直す。
    private let linkCards: LinkCardRefresher
    /// 「操作の状況」の一覧に並べる、処理の途中と最近の失敗。
    let operationStatus = OperationStatus()
    /// 添付ファイルのビューアで、共有や保存のために落とす処理。ビューアを閉じても保存を続け、閉じたあとの知らせは一覧に出す。
    private lazy var mediaTransfers = MediaTransferCenter(operationStatus: operationStatus)
    /// APIが401を返したときに、トークンが本当に無効かを確かめる。
    private let authorization: AuthorizationCheck
    private let onReauthenticate: (SessionController) async -> Void
    /// ログインし直しの途中。続けて押されても、認可画面を重ねて出さない。
    private var isReauthenticating = false
    private let tabBarDelegate: TabReselectionDelegate
    /// 開いているプロフィール画面。投稿への操作の結果を反映するために持つ。閉じたものは自然に消える。
    private let profiles: ProfileRegistry
    private var cachedMyAccount: Account?
    /// タブバーの上の投稿欄。ホームと通知のどちらでも同じ下書きを使う。
    private let composer: InlineComposeController
    /// 投稿欄が覆っている高さを伝える一覧。ホームと通知に加え、開いているプロフィールの一覧も入る。閉じたものは自然に消える。
    private let timelines = NSHashTable<TimelineViewController>.weakObjects()
    /// 添付ファイルを覆うか。ホームと通知とプロフィールでそろえ、閉じて開き直したプロフィールにも引き継ぐ。
    private var mediaCovers = MediaCovers()
    /// fxtwitterから読んだXの投稿。ホームと通知とプロフィールで同じ投稿を1回だけ読む。
    private let xPosts = XPostStore(client: XPostClient(transport: URLSessionTransport()))
    private var composerObscuredHeight: CGFloat = 0
    /// 本文のリンクを開くアプリ内のSafari。シートが覆っている高さも、投稿欄と同じく一覧の下の余白にする。
    private let browser = InAppBrowser()
    private var browserObscuredHeight: CGFloat = 0
    private var browserCoversTimelines = false
    /// 一覧の下を覆っている高さ。投稿欄とアプリ内のSafariのシートのうち、高いほう。
    private var obscuredBottomHeight: CGFloat { max(composerObscuredHeight, browserObscuredHeight) }
    /// 投稿欄で使う、インスタンスの上限。一度読めたら使い回す。
    private var instanceConfiguration: InstanceConfiguration?
    /// アカウントの設定。一度読めたら使い回す。
    private var preferences: ServerPreferences?
    private let logger = SciaLog.logger(category: "session")

    /// - Parameters:
    ///   - accountMenu: アカウントの切り替えなどのメニュー。開くたびに呼んで組み立て直す。
    ///   - onReauthenticate: トークンが無効なアカウントで、ログインし直しのボタンが押されたときに呼ぶ。ログインし直しが終わるか、取り消されたら返る。
    init(credential: Credential, accountMenu: @escaping @MainActor () -> UIMenu, onReauthenticate: @escaping (SessionController) async -> Void) {
        self.credential = credential
        self.onReauthenticate = onReauthenticate
        #if DEBUG
        let client = MastodonClient(credential: credential, transport: FaultInjectingTransport(base: URLSessionTransport()), rateLimit: rateLimit, features: features, requestLog: requestLog)
        #else
        let client = MastodonClient(credential: credential, transport: URLSessionTransport(), rateLimit: rateLimit, features: features, requestLog: requestLog)
        #endif
        #if DEBUG
        let streaming = StreamingClient(credential: credential, connector: FaultInjectingWebSocketConnector(base: URLSessionWebSocketConnector()))
        #else
        let streaming = StreamingClient(credential: credential, connector: URLSessionWebSocketConnector())
        #endif
        authorization = AuthorizationCheck { try await client.verifyCredentials() }
        // selfを作り終える前に組み立てる部品から呼ぶため、後で中身を差し替える。
        var forward: () -> Void = {}
        let streamingEndpoint = StreamingEndpoint(client: client)
        let tuning = AppDependencies.tuning
        let streamingHub = StreamingHub(livePolicy: { TuningCatalog.liveUpdates(in: tuning) }) {
            streaming.open(baseURL: try await streamingEndpoint.url())
        }
        self.streamingHub = streamingHub
        let home = HomeTimelineController(client: client, streamingHub: streamingHub) { forward() }
        let notifications = NotificationsController(client: client, streamingHub: streamingHub) { forward() }
        self.home = home
        self.notifications = notifications
        let diagnostics = ConnectionDiagnostics(rateLimit: rateLimit, features: features, requestLog: requestLog)
        self.diagnostics = diagnostics
        // コントローラーはHubを持っているので、弱く持って循環させない。
        streamingHub.onChange = { [weak streamingHub, weak home, weak notifications] in
            guard let streamingHub else { return }
            diagnostics.setStreaming(streamingHub.state, subscriptions: streamingHub.subscriptions)
            home?.showStreamingState(streamingHub.state)
            notifications?.showStreamingState(streamingHub.state)
        }
        streamingHub.onUnauthorized = { forward() }
        self.client = client
        let profiles = ProfileRegistry()
        self.profiles = profiles
        // 同じ投稿が両方のタブと開いているプロフィールにあることがあるため、どれにも反映する。
        interactions = StatusInteractions(operations: .init(client: client)) { id, transform in
            home.updateStatus(id, transform)
            notifications.updateStatus(id, transform)
            profiles.updateStatus(id, transform)
        }
        linkCards = LinkCardRefresher(client: client) { refetched in
            for update in [home.updateStatus, notifications.updateStatus, profiles.updateStatus] {
                update(refetched.id) { $0.adoptingCard(of: refetched) }
            }
        }

        let homeNavigation = UINavigationController(rootViewController: home.viewController)
        let notificationsNavigation = UINavigationController(rootViewController: notifications.viewController)
        let notificationsTab = UITab(title: "通知", image: UIImage(systemName: "bell"), identifier: "notifications") { _ in notificationsNavigation }
        notifications.onUnreadCountChange = { count, isLowerBound in
            notificationsTab.badgeValue = count == 0 ? nil : isLowerBound ? "\(count)+" : "\(count)"
        }
        let tabBarController = UITabBarController(tabs: [
            UITab(title: "ホーム", image: UIImage(systemName: "house"), identifier: "home") { _ in homeNavigation },
            notificationsTab,
        ])
        tabBarDelegate = TabReselectionDelegate { navigation in
            (navigation.viewControllers.first as? TimelineViewController)?.scrollToNewest()
        }
        tabBarController.delegate = tabBarDelegate
        // トークンの失効は、どのAPIで分かっても同じくログインし直しを促す。
        let reportIfUnauthorized = { (error: any Error) in
            if let error = error as? MastodonAPIError, error.isUnauthorized {
                forward()
            }
        }
        let media = ComposeMediaService(
            upload: { upload in
                do {
                    return try await client.uploadMedia(upload)
                } catch {
                    reportIfUnauthorized(error)
                    throw error
                }
            },
            waitUntilProcessed: { id in
                do {
                    return try await client.waitUntilProcessed(id)
                } catch {
                    reportIfUnauthorized(error)
                    throw error
                }
            },
            updateDescription: { id, description in
                do {
                    return try await client.updateMediaDescription(id, description: description)
                } catch {
                    reportIfUnauthorized(error)
                    throw error
                }
            },
            makeThumbnail: { file in await LocalMediaThumbnail.make(for: file, maxPixelSize: ComposeAttachmentStrip.thumbnailPixelSize) }
        )
        // 補完の問い合わせ口は別のスレッドから呼ばれるため、ほかの口と同じ知らせ方を、隔離されたAuthorizationCheckに直接送る。
        let reportCompletionFailure: @Sendable (any Error) async -> Void = { [authorization] error in
            guard let error = error as? MastodonAPIError, error.isUnauthorized else { return }
            _ = await authorization.reportUnauthorized()
        }
        let completionSources = ComposeCompletion.Sources(
            searchAccounts: { query, limit in
                do {
                    return try await client.searchAccountsForCompletion(query, limit: limit)
                } catch {
                    await reportCompletionFailure(error)
                    throw error
                }
            },
            searchHashtags: { query, limit in
                do {
                    return try await client.searchHashtagsForCompletion(query, limit: limit)
                } catch {
                    await reportCompletionFailure(error)
                    throw error
                }
            },
            customEmojis: {
                do {
                    return try await client.customEmojis()
                } catch {
                    await reportCompletionFailure(error)
                    throw error
                }
            },
            featuredTags: {
                do {
                    return try await client.featuredTags()
                } catch {
                    await reportCompletionFailure(error)
                    throw error
                }
            },
            recentTags: {
                do {
                    return try await client.featuredTagSuggestions()
                } catch {
                    await reportCompletionFailure(error)
                    throw error
                }
            }
        )
        composer = InlineComposeController(
            model: ComposeModel(myAccountID: credential.accountID, media: media) { draft in
                do {
                    if let editing = draft.editing {
                        // ストリーミングの編集の知らせを待たずに、どの一覧にも編集したあとの投稿を出す。切れている間も直るようにするため。
                        let edited = try await client.editStatus(editing, to: draft)
                        for update in [home.updateStatus, notifications.updateStatus, profiles.updateStatus] {
                            update(edited.id) { _ in edited }
                        }
                    } else {
                        _ = try await client.postStatus(draft)
                    }
                } catch {
                    reportIfUnauthorized(error)
                    throw error
                }
            },
            completion: ComposeCompletion(sources: completionSources, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning))
        )
        rootViewController = tabBarController
        forward = { [weak self] in self?.reportUnauthorized() }
        authorization.onChange = { [weak self] state in
            guard state == .invalid else { return }
            self?.credentialsDidBecomeInvalid()
        }
        for viewController in [home.viewController, notifications.viewController] {
            viewController.navigationItem.leftBarButtonItem = Self.accountButton(for: credential) { [weak self, weak viewController] in
                let myProfile = UIAction(title: "自分のプロフィール", image: UIImage(systemName: "person.crop.circle")) { _ in
                    guard let viewController else { return }
                    self?.openMyProfile(from: viewController)
                }
                let recent = UIAction(title: "操作の状況", image: UIImage(systemName: "list.bullet.clipboard")) { _ in
                    self?.showOperationStatus()
                }
                return UIMenu(children: [UIMenu(options: .displayInline, children: [myProfile, recent])] + accountMenu().children)
            }
            #if DEBUG
            viewController.onDebugURL = { [weak self] url in self?.handle(url) }
            #endif
            configure(viewController)
        }
        composer.onBeginEditing = { [weak self] in
            self?.applyComposeDefaults()
            // アプリ内のSafariのシートは投稿欄より手前に出るため、書いている間は伏せた高さまで下げる。
            self?.browser.lowerForCompose()
        }
        composer.onEndEditing = { [weak self] in self?.browser.restoreAfterCompose() }
        composer.presenterAboveInlineCompose = { [weak tabBarController] in
            // 投稿欄より手前にあるのは、アプリ内のSafariのシートだけのとき。ほかの画面を出していれば、その上には重ねない。
            guard let tabBarController else { return nil }
            let top = tabBarController.frontmostPresented
            return top === tabBarController || top is SFSafariViewController ? top : nil
        }
        composer.onShowReplyTarget = { [weak tabBarController] status in
            // 今見えている一覧（ホーム、通知、開いているプロフィール）に返信先があれば、そこへ戻る。なければ動かさない。
            let navigation = tabBarController?.selectedTab?.viewController as? UINavigationController
            (navigation?.topViewController as? TimelineViewController)?.scrollToStatus(status.id, displayedID: status.displayed.id)
        }
        composer.onObscuredHeightChange = { [weak self] height in
            guard let self else { return }
            composerObscuredHeight = height
            applyObscuredBottomHeight()
        }
        browser.onObscuredHeightChange = { [weak self] height in
            guard let self else { return }
            browserObscuredHeight = height
            applyObscuredBottomHeight()
        }
        browser.onPresenceChange = { [weak self] presented in
            guard let self else { return }
            for timeline in timelines.allObjects {
                timeline.setShowsFocusInlineCompose(presented)
            }
        }
        browser.onCoverageChange = { [weak self] covered in
            guard let self else { return }
            browserCoversTimelines = covered
            for timeline in timelines.allObjects {
                timeline.setCoveredByInAppBrowser(covered)
            }
        }
        mediaTransfers.showOperationStatus = { [weak self] presenter in self?.showOperationStatus(from: presenter) }
        mediaTransfers.host = MediaTransferCenter.Host(
            setPersistent: { [weak self] notice in
                for timeline in self?.timelines.allObjects ?? [] {
                    timeline.setPersistentNotice(notice)
                }
            },
            showTransient: { [weak self] notice, duration, replacesPersistent in
                self?.visibleTimeline?.showNotice(notice, duration: duration, replacesPersistent: replacesPersistent)
            },
            presenter: { [weak self] in self?.topViewController }
        )
        xPosts.onLoad = { [weak self] id in
            for timeline in self?.timelines.allObjects ?? [] {
                timeline.applyXPost(id: id)
            }
        }
        // 投稿欄を置くとタブバーの画面を読み込むため、各一覧の設定を終えてから置く。
        composer.install(in: tabBarController)
    }

    /// いま見えている一覧（ホーム、通知、開いているプロフィール）。ほかの画面を開いていればnil。
    private var visibleTimeline: TimelineViewController? {
        let navigation = (rootViewController as? UITabBarController)?.selectedTab?.viewController as? UINavigationController
        return navigation?.topViewController as? TimelineViewController
    }

    private func applyObscuredBottomHeight() {
        for timeline in timelines.allObjects {
            timeline.setObscuredBottomHeight(obscuredBottomHeight)
        }
    }

    /// 一覧から投稿への操作とプロフィールを開けるようにする。プロフィール画面の一覧にも使う。
    private func configure(_ viewController: TimelineViewController) {
        timelines.add(viewController)
        if authorization.state == .invalid {
            showReauthenticationPrompt(on: viewController)
            viewController.setReauthenticating(isReauthenticating)
        }
        viewController.setObscuredBottomHeight(obscuredBottomHeight)
        viewController.setCoveredByInAppBrowser(browserCoversTimelines)
        viewController.onFocusInlineCompose = { [weak self] in self?.composer.beginEditing() }
        viewController.setShowsFocusInlineCompose(browser.isPresented)
        viewController.myAccountID = credential.accountID
        viewController.spoilerExpansion.expandsByDefault = preferences?.expandsSpoilers ?? false
        viewController.mediaCovers = mediaCovers
        viewController.xPosts = xPosts
        viewController.onChangeMediaCovers = { [weak self, weak viewController] covers, status in
            self?.shareMediaCovers(covers, changed: status, from: viewController)
        }
        viewController.onStatusAction = { [weak self, weak viewController] action, status in self?.perform(action, on: status, from: viewController) }
        viewController.onShowOperationStatus = { [weak self] presenter in self?.showOperationStatus(from: presenter) }
        viewController.mediaTransfers = mediaTransfers
        mediaTransfers.updateTimelineChip()
        viewController.onOpenProfile = { [weak self, weak viewController] account in
            guard let viewController else { return }
            self?.openProfile(account, from: viewController)
        }
        viewController.onOpenProfileID = { [weak self, weak viewController] accountID in
            guard let viewController else { return }
            self?.openProfile(accountID: accountID, from: viewController)
        }
        viewController.onOpenLink = { [weak self, weak viewController] destination, status in
            guard let viewController else { return }
            self?.open(destination, in: status, from: viewController)
        }
        viewController.onVisibleLinkOnlyCardsChange = { [weak self, weak viewController] statuses in
            guard let self, let viewController else { return }
            #if DEBUG
            // ダミー投稿はサーバーにないため、取り直さない。カードはダミーを流した側が届ける。
            let statuses = statuses.filter { !self.home.isDebugLocalOnly($0.id) }
            #endif
            self.linkCards.setVisible(statuses, from: viewController)
        }
    }

    /// 一覧で開いたり隠したりした結果を、ほかの一覧にもそろえる。
    private func shareMediaCovers(_ covers: MediaCovers, changed status: Status, from source: TimelineViewController?) {
        mediaCovers = covers
        for timeline in timelines.allObjects where timeline !== source {
            timeline.applyMediaCovers(covers, changed: status)
        }
    }

    /// 本文のリンクを開く。URLは設定に応じて既定のブラウザかアプリ内のSafariで、メンションはその人のプロフィールを開いた一覧に積む。
    /// ハッシュタグはまだハッシュタグのタイムラインがないため、押しても何もしない。ブラウザで開くと、タイムラインを足したときに挙動が変わってしまう。
    private func open(_ destination: RichText.LinkDestination, in status: Status, from source: UIViewController) {
        switch destination {
        case .url(let url):
            switch AppDependencies.settings.linkBrowser.browser(for: url) {
            case .external: UIApplication.shared.open(url)
            case .inApp: browser.open(url, from: rootViewController)
            }
        case .mention(let acct, let url):
            // ローカルのacctはドメインを含まず、検索では完全一致にならないため、投稿のメンションの一覧にあるIDで引く。
            guard let mention = status.mentions.first(where: { $0.url == url || $0.acct == acct }) else {
                logger.error("mention not in status acct=\(acct, privacy: .public)")
                handle(ProfileNotFound(acct: acct), title: "プロフィールを開けませんでした")
                return
            }
            openProfile(accountID: mention.id, from: source)
        case .hashtag:
            break
        }
    }

    private func openProfile(accountID: String, from source: UIViewController) {
        let client = client
        Task {
            do {
                let account = try await client.account(accountID)
                openProfile(account, from: source)
            } catch {
                handle(error, title: "プロフィールを開けませんでした")
            }
        }
    }

    // MARK: - プロフィール

    private func openProfile(_ account: Account, from source: UIViewController) {
        let (controller, viewController) = ProfileController.make(account: account, client: client) { [weak self] error, title in
            self?.handle(error, title: title)
        } onUnauthorized: { [weak self] in
            self?.reportUnauthorized()
        }
        UserAction.openProfile.record()
        configure(viewController)
        profiles.add(controller)
        source.navigationController?.pushViewController(viewController, animated: true)
        controller.start()
    }

    /// ログイン中のアカウント。手元にはCredentialしかないため、一度読んだら使い回す。
    func myAccount() async throws -> Account {
        if let cachedMyAccount { return cachedMyAccount }
        let account = try await client.account(client.credential.accountID)
        cachedMyAccount = account
        return account
    }

    private func openMyProfile(from source: UIViewController) {
        Task {
            do {
                let account = try await myAccount()
                openProfile(account, from: source)
            } catch {
                logger.error("my profile load failed: \(SciaLog.describe(error), privacy: .public)")
                handle(error, title: "プロフィールを読み込めませんでした")
            }
        }
    }

    /// 使っているアカウントを示し、押すとアカウントのメニューを開く。
    private static func accountButton(for credential: Credential, menu: @escaping @MainActor () -> UIMenu) -> UIBarButtonItem {
        let deferred = UIDeferredMenuElement.uncached { completion in
            completion(menu().children)
        }
        let item = UIBarButtonItem(image: UIImage(systemName: "person.crop.circle"), menu: UIMenu(children: [deferred]))
        item.accessibilityLabel = "アカウント"
        item.accessibilityValue = credential.handle
        return item
    }

    // MARK: - 操作の状況

    /// 「操作の状況」の一覧をシートで開く。行の投稿を選んだら、シートを閉じてから開く。
    /// ビューアのチップから開いたときは、投稿が裏の一覧で動いても見えないため、ビューアも閉じ終えてから開く。
    /// - Parameter presenter: シートを出す画面。nilならいちばん手前の画面。
    func showOperationStatus(from presenter: UIViewController? = nil) {
        weak var sheet: UIViewController?
        let controller = OperationStatusView.makeSheet(notices: operationStatus) { [weak self, weak presenter] subject in
            sheet?.dismiss(animated: true) {
                guard let viewer = presenter as? MediaViewerController else {
                    self?.open(subject)
                    return
                }
                viewer.onCloseFinish = { [weak self] in self?.open(subject) }
                viewer.close()
            }
        }
        sheet = controller
        (presenter ?? topViewController).present(controller, animated: true)
    }

    /// 投稿の詳細の画面はまだないため、今見えている一覧（ホーム、通知、開いているプロフィール）にあればそこへ動かし、なければ投稿のページを開く。
    private func open(_ subject: OperationStatus.Subject) {
        let navigation = (rootViewController as? UITabBarController)?.selectedTab?.viewController as? UINavigationController
        if let timeline = navigation?.topViewController as? TimelineViewController,
           timeline.scrollToStatus(subject.statusID, displayedID: subject.displayedID, at: .centeredVertically) {
            return
        }
        if let url = subject.url {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 投稿への操作

    /// - Parameter timeline: 操作した一覧。失敗したら、そこに知らせを出す。
    private func perform(_ action: StatusAction, on status: Status, from timeline: TimelineViewController?) {
        switch action {
        case .reply:
            UserAction.reply.record()
            confirmLeavingEdit { [weak self] in self?.composer.reply(to: status) }
        case .favourite:
            UserAction.toggleFavourite.record()
            toggle(.favourite, on: status, failureTitle: "お気に入りを変更できませんでした", from: timeline)
        case .reblog:
            UserAction.toggleReblog.record()
            toggle(.reblog, on: status, failureTitle: "ブーストを変更できませんでした", from: timeline)
        case .edit:
            UserAction.editStatus.record()
            startEditing(status, from: timeline)
        case .delete:
            confirmDeleting(status, from: timeline)
        }
    }

    /// 編集している途中で返信を選んだら、編集をやめてよいか聞いてから返信を始める。編集でなければすぐ始める。
    /// 返信は書いた本文を残して返信先を付け替えるが、編集の本文は元の投稿のものなので、返信には引き継がない。
    private func confirmLeavingEdit(_ proceed: @escaping () -> Void) {
        guard composer.model.editedStatus != nil else {
            proceed()
            return
        }
        let alert = UIAlertController(title: "編集をやめて返信しますか？", message: "編集中の内容は消えます。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "編集をやめる", style: .destructive) { [weak self] _ in
            // 編集を送っている間はやめず、返信も始めない。送り終えれば空に戻るので、返信はそのあと選び直してもらう。
            guard self?.composer.cancelStatusEdit() == true else { return }
            proceed()
        })
        topViewController.present(alert, animated: true)
    }

    /// 編集の元にする本文をサーバーから読み、読めたら投稿欄で編集を始める。同じ投稿を編集している途中なら、読み直さずに投稿欄を開く。
    /// 読めなかったら、お気に入りの失敗と同じく、操作した一覧にチップを出す。
    private func startEditing(_ status: Status, from timeline: TimelineViewController?) {
        let target = status.displayed
        if composer.model.editedStatus?.id == target.id {
            composer.beginEditing()
            return
        }
        let client = client
        Task { [weak self, weak timeline] in
            do {
                let source = try await client.statusSource(target.id)
                self?.confirmEditing(target, source: source)
            } catch {
                guard let self else { return }
                let title = "編集を始められませんでした"
                logger.error("edit source failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason, subject: OperationStatus.Subject(status))
                timeline?.showNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    /// 書きかけの下書きがあれば捨ててよいかを、投票の付いた投稿なら締め切りがずれることを、聞いてから編集を始める。どちらもなければすぐ始める。
    /// 本文を読んでから聞く。先に聞くと、読んでいる間に書いたものを、聞かずに捨ててしまうため。
    private func confirmEditing(_ status: Status, source: StatusSource) {
        guard status.canBeEdited(now: Date()) else {
            presentPollTooCloseAlert()
            return
        }
        let discards = composer.model.hasWrittenContent
        let hasPoll = status.poll != nil
        guard discards || hasPoll else {
            composer.edit(status, source: source)
            return
        }
        var lines: [String] = []
        if discards {
            lines.append(composer.model.editedStatus != nil ? "編集中の内容は消えます。" : "書きかけの下書きは消えます。")
        }
        if hasPoll {
            lines.append("投票はそのまま残りますが、締め切りは送った時点から数え直すため、少しずれます。")
        }
        let alert = UIAlertController(title: discards ? "下書きを捨てて編集しますか？" : "投票の付いた投稿を編集しますか？", message: lines.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: discards ? "捨てて編集" : "編集", style: discards ? .destructive : .default) { [weak self] _ in
            guard let self else { return }
            // 聞いている間に締め切りが近づいたら、投票なしで送って投票を消さないよう、編集を始めない。
            if !status.canBeEdited(now: Date()) {
                presentPollTooCloseAlert()
            } else {
                composer.edit(status, source: source)
            }
        })
        topViewController.present(alert, animated: true)
    }

    /// メニューを出してから編集を始めるまでに、投票の締め切りまで5分を切ったとき。
    private func presentPollTooCloseAlert() {
        presentAlert(title: "編集できません", message: "投票の締め切りまで5分を切ったため、この投稿は編集できません。")
    }

    /// 削除は元に戻せないので、確かめてから送る。
    private func confirmDeleting(_ status: Status, from timeline: TimelineViewController?) {
        let alert = UIAlertController(title: "投稿を削除しますか？", message: "削除した投稿は元に戻せません。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self, weak timeline] _ in
            self?.delete(status, from: timeline)
        })
        topViewController.present(alert, animated: true)
    }

    /// 消えたらどの一覧からも除く。編集している投稿を消したら、編集もやめる。
    /// 失敗は押し直せば済むので、お気に入りの失敗と同じく、操作した一覧にチップを出す。
    private func delete(_ status: Status, from timeline: TimelineViewController?) {
        UserAction.deleteStatus.record()
        let target = status.displayed
        let client = client
        Task { [weak self, weak timeline] in
            do {
                try await client.deleteStatus(target.id)
                guard let self else { return }
                home.removeStatus(target.id)
                notifications.removeStatus(target.id)
                profiles.removeStatus(target.id)
                if composer.model.editedStatus?.id == target.id {
                    composer.cancelStatusEdit()
                }
            } catch {
                guard let self else { return }
                let title = "投稿を削除できませんでした"
                logger.error("delete failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason, subject: OperationStatus.Subject(status))
                timeline?.showNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    /// 押し直せば済む失敗なので、操作を止めるアラートにせず、操作した一覧に数秒で消えるチップを出し、押すと理由を出す。
    /// 消えたあとも確かめられるよう、「最近の失敗」に残す。
    private func toggle(_ action: StatusInteractions.Action, on status: Status, failureTitle: String, from timeline: TimelineViewController?) {
        let interactions = interactions
        Task { [weak self, weak timeline] in
            do {
                try await interactions.toggle(action, on: status)
            } catch {
                guard let self else { return }
                logger.error("toggle \(String(describing: action), privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: failureTitle, reason: reason, subject: OperationStatus.Subject(status))
                timeline?.showNotice(.interactionFailure(title: failureTitle) { [weak self] in
                    self?.presentAlert(title: failureTitle, message: reason.text)
                })
            }
        }
    }

    private func handle(_ error: any Error, title: String) {
        guard let apiError = error as? MastodonAPIError, apiError.isUnauthorized else {
            presentAlert(title: title, message: ErrorPresentation(error).text)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let reason = await self.failureReason(for: error)
            self.presentAlert(title: title, message: reason.text)
        }
    }

    /// 失敗の理由。401なら、一部のAPIだけが401を返すこともあるため、トークンが本当に無効かを確かめてから文言を選ぶ。
    /// 無効だと分かれば、ログインし直しのボタンも出る。
    private func failureReason(for error: any Error) async -> ErrorPresentation {
        guard let apiError = error as? MastodonAPIError, apiError.isUnauthorized else {
            return ErrorPresentation(error)
        }
        let state = await authorization.reportUnauthorized()
        return state == .invalid ? ErrorPresentation(message: Self.reauthenticationMessage, code: nil) : ErrorPresentation(error)
    }

    private static let reauthenticationMessage = "ログインの有効期限が切れたか、アプリの許可が取り消されました。上のボタンからログインし直してください。"

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        topViewController.present(alert, animated: true)
    }

    /// いちばん手前に出ている画面。
    private var topViewController: UIViewController {
        var top = rootViewController
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - 投稿

    /// 既定の公開範囲などを読めたら、投稿欄に反映する。読めなかったら、次に書き始めたときに読み直す。
    private func applyComposeDefaults() {
        Task { [weak self] in
            guard let self else { return }
            async let configuration = self.loadInstanceConfiguration()
            async let preferences = self.loadPreferences()
            self.composer.model.apply(configuration: await configuration, defaultVisibility: await preferences?.defaultVisibility, defaultSensitive: await preferences?.defaultSensitive)
        }
    }

    /// 読めなければ、既定のまま投稿欄を使えるようnilを返し、次に書き始めたときに読み直す。
    private func loadInstanceConfiguration() async -> InstanceConfiguration? {
        if let instanceConfiguration { return instanceConfiguration }
        instanceConfiguration = try? await client.instanceConfiguration()
        return instanceConfiguration
    }

    /// アカウントの設定を読み、注意書きを最初から開いておくかを一覧に反映する。
    /// 読めなければnilを返す。一覧は注意書きを畳んだままにし、次に投稿欄で書き始めたときに読み直す。
    @discardableResult
    private func loadPreferences() async -> ServerPreferences? {
        if let preferences { return preferences }
        do {
            let loaded = try await client.preferences()
            preferences = loaded
            for timeline in timelines.allObjects {
                timeline.spoilerExpansion.expandsByDefault = loaded.expandsSpoilers
            }
            return loaded
        } catch {
            logger.info("preferences unavailable error=\(SciaLog.describe(error), privacy: .public)")
            return nil
        }
    }

    func start() {
        home.start()
        notifications.start()
        observeRecoveries()
        loadServerVersion()
        RequestOrigin.$current.withValue(.automatic) {
            Task { [weak self] in await self?.loadPreferences() }
        }
    }

    /// 原因を絞れるよう、サーバーの版を記録に残す。読めなくても使うのに困らないので、失敗は記録するだけにする。
    private func loadServerVersion() {
        let client = client
        let instance = credential.instance.host() ?? credential.instance.absoluteString
        RequestOrigin.$current.withValue(.automatic) {
            Task { [weak self] in
                do {
                    let version = try await client.serverVersion()
                    self?.logger.info("server instance=\(instance, privacy: .public) version=\(version, privacy: .public)")
                    self?.diagnostics.setServerVersion(version)
                } catch {
                    self?.logger.info("server version unavailable instance=\(instance, privacy: .public) error=\(SciaLog.describe(error), privacy: .public)")
                }
            }
        }
    }

    private func observeRecoveries() {
        let rateLimit = rateLimit
        let network = AppDependencies.network
        recoveryTasks.append(Task { [weak self] in
            for await _ in rateLimit.resumptions {
                self?.recover(reason: "rate limit resumed")
            }
        })
        recoveryTasks.append(Task { [weak self] in
            // 最初の値は今の回数なので飛ばす。
            for await _ in Observations({ network.recoveryCount }).dropFirst() {
                self?.recover(reason: "network recovered")
            }
        })
    }

    private func recover(reason: String) {
        logger.info("recover reason=\(reason, privacy: .public)")
        // つながっていなければ、待っている間隔を飛ばしてつなぎ直す。
        streamingHub.recover()
        home.recover()
        notifications.recover()
    }

    // MARK: - ログインし直し

    private func reportUnauthorized() {
        Task { await authorization.reportUnauthorized() }
    }

    /// トークンが無効だと確かめられたら、表示中の内容とアカウントのメニューは残したまま、自動の通信を止めてログインし直しを促す。
    /// 資格情報は消さない。消すのは、使う人がログアウトを選んだときだけ。
    private func credentialsDidBecomeInvalid() {
        logger.info("credentials invalid")
        streamingHub.stopUntilLogin()
        home.stop()
        notifications.stop()
        for timeline in timelines.allObjects {
            showReauthenticationPrompt(on: timeline)
        }
    }

    /// 一覧の再試行ボタンも、ログインし直しにする。止めた後の再試行は何も読まず、ログインし直すまで読み込めないため。
    private func showReauthenticationPrompt(on viewController: TimelineViewController) {
        viewController.showReauthenticationPrompt(handle: credential.handle) { [weak self] in
            self?.reauthenticate()
        }
        viewController.onRetry = { [weak self] in self?.reauthenticate() }
        // 読み込みの途中で止めた一覧が、読み込み中のまま残らないようにする。
        let message = ErrorPresentation(message: "ログインし直すと読み込めます。", code: nil)
        if viewController.contentState == .loading {
            viewController.setContentState(.failed(message))
        }
        if viewController.footerState == .loading {
            viewController.setFooterState(.failed(message))
        }
    }

    private func reauthenticate() {
        guard !isReauthenticating else { return }
        setReauthenticating(true)
        Task {
            await onReauthenticate(self)
            setReauthenticating(false)
        }
    }

    private func setReauthenticating(_ isReauthenticating: Bool) {
        self.isReauthenticating = isReauthenticating
        for timeline in timelines.allObjects {
            timeline.setReauthenticating(isReauthenticating)
        }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときに呼ぶ。
    func stop() {
        home.stop()
        notifications.stop()
        recoveryTasks.forEach { $0.cancel() }
        recoveryTasks.removeAll()
    }

    /// 他のアプリから開かれたURLの画面を出す。
    func open(_ url: AppURL) {
        switch url {
        case .profile(let acct):
            openProfile(acct: acct)
        }
    }

    /// acctでアカウントを探して、ホームのタブにプロフィールを開く。ホームを選んでいなければホームに切り替える。
    private func openProfile(acct: String) {
        let client = client
        Task {
            do {
                guard let account = try await client.resolveAccount(acct) else {
                    logger.error("profile not found acct=\(acct, privacy: .public)")
                    handle(ProfileNotFound(acct: acct), title: "プロフィールを開けませんでした")
                    return
                }
                (rootViewController as? UITabBarController)?.selectedIndex = 0
                openProfile(account, from: home.viewController)
            } catch {
                handle(error, title: "プロフィールを開けませんでした")
            }
        }
    }

    #if DEBUG
    func handle(_ url: DebugURL) {
        switch url {
        case .dummy(let post):
            home.streamDummy(post)
        case .unauthorized:
            DebugFaults.rejectAsUnauthorized()
            reportUnauthorized()
        case .unreadable:
            DebugFaults.corruptListElements()
            home.start()
            notifications.start()
        case .status(let statusCode, let retryAfter):
            DebugFaults.fail(withStatus: statusCode, retryAfter: retryAfter)
            home.start()
            notifications.start()
        case .statusCleared:
            DebugFaults.fail(withStatus: nil)
        case .unsupported(let feature):
            DebugFaults.makeUnsupported(feature)
            home.start()
            notifications.start()
        case .regenerating(let isOn):
            DebugFaults.setRegeneratingHome(isOn)
        case .streaming(let isOnline):
            DebugFaults.setStreamingOnline(isOnline)
        case .slowDownload(let seconds):
            DebugFaults.slowDownloads(by: seconds.map { .seconds($0) })
        case .catalog(let component):
            topViewController.presentComponentCatalog(opening: component)
        case .dump:
            AgentScreenDump.write(scene: rootViewController.view.window?.windowScene)
        case .reset:
            rootViewController.dismiss(animated: false)
            let tabs = rootViewController as? UITabBarController
            for case let navigation as UINavigationController in tabs?.viewControllers ?? [] {
                navigation.popToRootViewController(animated: false)
            }
            tabs?.selectedIndex = 0
        case .settings:
            // 直前のresetで閉じている途中の画面には重ねられないため、閉じる途中の画面を飛ばして重ねる。
            rootViewController.frontmostPresented.presentSettings(
                loadPreviewAccount: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.myAccount()
                },
                instance: credential.instance,
                diagnostics: diagnostics
            )
        case .tuning:
            rootViewController.frontmostPresented.presentTuningPanel()
        case .tab(let tab):
            (rootViewController as? UITabBarController)?.selectedIndex = tab == .home ? 0 : 1
        case .viewer(let index):
            openTopmostMedia(at: index)
        case .holdArrivals(let isOn):
            DebugFaults.setHoldingArrivals(isOn)
            if !isOn {
                home.releaseHeldArrivals()
                notifications.releaseHeldArrivals()
            }
        }
    }

    /// 選んでいるタブで、画面のいちばん上に見えている添付ファイル付きの投稿を、サムネイルをタップしたのと同じ経路でビューアに開く。
    private func openTopmostMedia(at index: Int) {
        guard let view = (rootViewController as? UITabBarController)?.selectedViewController?.view, let window = view.window else { return }
        let grids = Self.mediaGrids(in: view)
            .filter { grid in
                guard let content = grid.content, !content.isCovered, index < content.attachments.count else { return false }
                return grid.convert(grid.bounds, to: window).intersects(window.bounds)
            }
            .sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
        guard let grid = grids.first else {
            logger.error("debug viewer: no visible media with index=\(index, privacy: .public)")
            return
        }
        grid.onSelect?(index)
    }

    private static func mediaGrids(in view: UIView) -> [MediaGridView] {
        guard !view.isHidden else { return [] }
        if let grid = view as? MediaGridView { return [grid] }
        return view.subviews.flatMap(mediaGrids(in:))
    }
    #endif

    func enterForeground() {
        home.enterForeground()
        notifications.enterForeground()
    }

    func enterBackground() {
        home.enterBackground()
        notifications.enterBackground()
    }
}

private struct ProfileNotFound: LocalizedError {
    let acct: String

    var errorDescription: String? { "@\(acct)が見つかりませんでした。" }
}

/// 開いているプロフィール画面を弱く持つ。
@MainActor
private final class ProfileRegistry {
    private struct Entry {
        weak var controller: ProfileController?
    }

    private var entries: [Entry] = []

    func add(_ controller: ProfileController) {
        entries.removeAll { $0.controller == nil }
        entries.append(Entry(controller: controller))
    }

    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        entries.removeAll { $0.controller == nil }
        for entry in entries {
            entry.controller?.updateStatus(id, transform)
        }
    }

    func removeStatus(_ id: Status.ID) {
        entries.removeAll { $0.controller == nil }
        for entry in entries {
            entry.controller?.removeStatus(id)
        }
    }
}

/// 選んでいるタブをもう一度押したとき、奥の画面を開いていれば標準どおり最初の画面へ戻し、最初の画面にいれば最上部へ動かす。
@MainActor
private final class TabReselectionDelegate: NSObject, UITabBarControllerDelegate {
    private let scrollToTop: (UINavigationController) -> Void

    init(scrollToTop: @escaping (UINavigationController) -> Void) {
        self.scrollToTop = scrollToTop
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab == tabBarController.selectedTab else {
            UserAction.selectTab(tab.identifier).record()
            return true
        }
        guard let navigation = tab.viewController as? UINavigationController,
              navigation.viewControllers.count == 1
        else {
            UserAction.reselectTab(tab.identifier).record()
            return true
        }
        // 慣性で動いている途中なら、最上部へ動かす時点でそれまでのスクロールが記録される。一覧で押した操作がその後に並ぶよう、後で記録する。
        scrollToTop(navigation)
        UserAction.reselectTab(tab.identifier).record()
        return false
    }
}
