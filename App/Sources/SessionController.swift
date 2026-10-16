import os
import SciaCore
import SwiftUI
import UIKit

/// ログイン中のアカウントの画面一式。タブの組み立てと、各タブの読み込みと接続の寿命をまとめる。
@MainActor
final class SessionController {
    let rootViewController: UIViewController
    /// このセッションで使っているアカウント。
    let credential: Credential
    private let home: HomeTimelineController
    private let notifications: NotificationsController
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
    /// 「最近の失敗」の一覧に並べる、処理の途中と最近の失敗。
    let recentNotices = RecentNotices()
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
    private var composerObscuredHeight: CGFloat = 0
    /// 投稿画面で使う、インスタンスの上限とユーザーの既定の公開範囲。一度読めたら使い回す。
    private var composeDefaults: (configuration: InstanceConfiguration?, visibility: Status.Visibility?)?
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
        // ホームと通知で、調べた接続先を使い回す。
        let streamingEndpoint = StreamingEndpoint(client: client)
        let home = HomeTimelineController(client: client, streaming: streaming, streamingEndpoint: streamingEndpoint) { forward() }
        let notifications = NotificationsController(client: client, streaming: streaming, streamingEndpoint: streamingEndpoint) { forward() }
        self.home = home
        self.notifications = notifications
        let diagnostics = ConnectionDiagnostics(rateLimit: rateLimit, features: features, requestLog: requestLog)
        self.diagnostics = diagnostics
        home.onStreamingStateChange = { diagnostics.setStreaming($0, for: .home) }
        notifications.onStreamingStateChange = { diagnostics.setStreaming($0, for: .notifications) }
        self.client = client
        let profiles = ProfileRegistry()
        self.profiles = profiles
        // 同じ投稿が両方のタブと開いているプロフィールにあることがあるため、どれにも反映する。
        interactions = StatusInteractions(operations: .init(client: client)) { id, transform in
            home.updateStatus(id, transform)
            notifications.updateStatus(id, transform)
            profiles.updateStatus(id, transform)
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
        composer = InlineComposeController(model: ComposeModel(myAccountID: credential.accountID, media: media) { draft in
            do {
                _ = try await client.postStatus(draft)
            } catch {
                reportIfUnauthorized(error)
                throw error
            }
        })
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
                let recent = UIAction(title: "最近の失敗", image: UIImage(systemName: "exclamationmark.circle")) { _ in
                    self?.showRecentNotices()
                }
                return UIMenu(children: [UIMenu(options: .displayInline, children: [myProfile, recent])] + accountMenu().children)
            }
            configure(viewController)
        }
        home.viewController.onCompose = { [weak self] in self?.expandCompose() }
        composer.onBeginEditing = { [weak self] in self?.applyComposeDefaults() }
        composer.onExpand = { [weak self] in self?.expandCompose() }
        composer.onShowReplyTarget = { [weak tabBarController] status in
            // 今見えている一覧（ホーム、通知、開いているプロフィール）に返信先があれば、そこへ戻る。なければ動かさない。
            let navigation = tabBarController?.selectedTab?.viewController as? UINavigationController
            (navigation?.topViewController as? TimelineViewController)?.scrollToStatus(status.id, displayedID: status.displayed.id)
        }
        composer.onObscuredHeightChange = { [weak self] height in
            guard let self else { return }
            composerObscuredHeight = height
            for timeline in timelines.allObjects {
                timeline.setObscuredBottomHeight(height)
            }
        }
        composer.onPosted = { [weak self] in
            guard let self, self.rootViewController.presentedViewController is ComposeHostingController else { return }
            self.rootViewController.dismiss(animated: true)
        }
        // 投稿欄を置くとタブバーの画面を読み込むため、各一覧の設定（投稿ボタンを付けるonComposeなど）を終えてから置く。
        composer.install(in: tabBarController)
    }

    /// 一覧から投稿への操作とプロフィールを開けるようにする。プロフィール画面の一覧にも使う。
    private func configure(_ viewController: TimelineViewController) {
        timelines.add(viewController)
        if authorization.state == .invalid {
            showReauthenticationPrompt(on: viewController)
            viewController.setReauthenticating(isReauthenticating)
        }
        viewController.setObscuredBottomHeight(composerObscuredHeight)
        viewController.myAccountID = credential.accountID
        viewController.onStatusAction = { [weak self, weak viewController] action, status in self?.perform(action, on: status, from: viewController) }
        viewController.onShowRecentNotices = { [weak self] presenter in self?.showRecentNotices(from: presenter) }
        viewController.onOpenProfile = { [weak self, weak viewController] account in
            guard let viewController else { return }
            self?.openProfile(account, from: viewController)
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

    // MARK: - 最近の失敗

    /// 「最近の失敗」の一覧をシートで開く。行の投稿を選んだら、シートを閉じてから開く。
    /// - Parameter presenter: シートを出す画面。nilならいちばん手前の画面。
    func showRecentNotices(from presenter: UIViewController? = nil) {
        weak var sheet: UIViewController?
        let controller = RecentNoticesView.makeSheet(notices: recentNotices) { [weak self] subject in
            sheet?.dismiss(animated: true) {
                self?.open(subject)
            }
        }
        sheet = controller
        (presenter ?? topViewController).present(controller, animated: true)
    }

    /// 投稿の詳細の画面はまだないため、今見えている一覧（ホーム、通知、開いているプロフィール）にあればそこへ動かし、なければ投稿のページを開く。
    private func open(_ subject: RecentNotices.Subject) {
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
            composer.reply(to: status)
        case .favourite:
            UserAction.toggleFavourite.record()
            toggle(.favourite, on: status, failureTitle: "お気に入りを変更できませんでした", from: timeline)
        case .reblog:
            UserAction.toggleReblog.record()
            toggle(.reblog, on: status, failureTitle: "ブーストを変更できませんでした", from: timeline)
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
                recentNotices.recordFailure(title: failureTitle, reason: reason, subject: RecentNotices.Subject(status))
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

    /// いちばん手前に出ている画面。投稿画面を出している間の失敗も、その上に出す。
    private var topViewController: UIViewController {
        var top = rootViewController
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - 投稿

    /// 投稿欄の下書きのまま、全画面の投稿画面を出す。
    private func expandCompose() {
        UserAction.expandCompose.record()
        applyComposeDefaults()
        rootViewController.present(ComposeHostingController(model: composer.model), animated: true)
    }

    /// 既定の公開範囲などを読めたら、投稿欄に反映する。読めなかったら、次に書き始めたときに読み直す。
    private func applyComposeDefaults() {
        Task { [weak self] in
            guard let self else { return }
            let defaults = await self.loadComposeDefaults()
            self.composer.model.apply(configuration: defaults.configuration, defaultVisibility: defaults.visibility)
        }
    }

    /// 読めなかった値は既定のまま投稿画面を使えるようnilにし、次に開いたときに読み直す。
    private func loadComposeDefaults() async -> (configuration: InstanceConfiguration?, visibility: Status.Visibility?) {
        if let composeDefaults { return composeDefaults }
        async let configuration = try? client.instanceConfiguration()
        async let visibility = try? client.defaultVisibility()
        let defaults = (await configuration, await visibility)
        if defaults.0 != nil, defaults.1 != nil {
            composeDefaults = defaults
        }
        return defaults
    }

    func start() {
        home.start()
        notifications.start()
        observeRecoveries()
        loadServerVersion()
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
        home.stopUntilLogin()
        notifications.stopUntilLogin()
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
        case .streaming(let isOnline):
            DebugFaults.setStreamingOnline(isOnline)
        case .slowDownload(let seconds):
            DebugFaults.slowDownloads(by: seconds.map { .seconds($0) })
        case .catalog(let component):
            topViewController.presentComponentCatalog(opening: component)
        }
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

/// 投稿欄を広げた画面を出す。閉じても下書きは投稿欄に残るため、下へのスワイプでも閉じられる。投稿中だけは閉じない。
@MainActor
private final class ComposeHostingController: UIHostingController<ComposeView>, UIAdaptivePresentationControllerDelegate {
    private let model: ComposeModel

    init(model: ComposeModel) {
        self.model = model
        super.init(rootView: ComposeView(model: model) {})
        // 閉じる操作は自分を参照するため、初期化を終えてから差し替える。
        rootView = ComposeView(model: model) { [weak self] in self?.dismiss(animated: true) }
        presentationController?.delegate = self
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !model.isPosting
    }
}
