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
    private let home: FeedTimelineController
    private let local: FeedTimelineController
    private let federated: FeedTimelineController
    private let notifications: NotificationsController
    /// 通知のフィルタリングの設定と、保留中の通知の人数。通知のタブのボタンと設定の画面が同じものを見る。
    private let notificationPolicy: NotificationPolicyModel
    /// サーバーのお知らせ。アカウントのボタンの点と、メニューから開くシートが同じものを見る。
    private let announcements: AnnouncementsModel
    /// タブの画面ごとに置いたアカウントのボタン。お知らせの未読の点を、どれにも付ける。
    private let accountButtons = NSHashTable<UIBarButtonItem>.weakObjects()
    /// 開いているお知らせのシート。
    private weak var presentedAnnouncements: UIViewController?
    private let bookmarks: SavedStatusesController
    private let favourites: SavedStatusesController
    /// 予約した投稿の一覧のタブ。
    private let scheduled: ScheduledStatusesController
    /// タブを無効にしているときに、手前に重ねて開いた予約の一覧。閉じたあとも、次に開くまで持つ。
    private var presentedScheduled: ScheduledStatusesController?
    /// リストとハッシュタグのタイムラインのタブ。並びに出たときに作る。
    private let serverFeeds: ServerFeedRegistry
    /// タブに置いたプロフィール。並びに出たときに作る。
    private let profileTabs: ProfileTabRegistry
    /// タブに置いたプロフィールで、記号の代わりに出すその人のアイコン。設定の並びにも出す。
    let profileTabIcons: ProfileTabIcons
    /// ハッシュタグのメニューやタップで、開いた一覧に積んだハッシュタグの一覧。
    private let pushedFeeds: PushedFeedRegistry
    /// 投稿の一覧のタブ。ホーム、ローカル、連合と、作ったリストとハッシュタグ。
    private var tabFeeds: [FeedTimelineController] { [home, local, federated] + serverFeeds.controllers }
    /// タブの一覧と、積んで開いているハッシュタグの一覧。
    private var feeds: [FeedTimelineController] { tabFeeds + pushedFeeds.controllers }
    /// 直近に読んだ自分のリスト。並びを最初の並びに戻したときに、リストを足し直すのに使う。
    /// リストの右上のメニューで、今の設定を出すのにも使う。アプリの中で作ったり変えたりしたら、読み直さずに入れる。
    private var loadedLists: [MastodonList]?
    /// アプリの中でリストを作ったり、変えたり、消したりした回数。読み始める前と読み終えたときで違えば、読んだ一覧はその変更より古いので使わない。
    private var listChangeCount = 0
    /// リストを作る、変える、消す。
    private lazy var listEditor = ListEditor(client: client, tasks: tasks.child(), host: self)
    /// 直近に読んだ、フォローしているハッシュタグ。並びを最初の並びに戻したときに、足し直すのに使う。
    private var loadedHashtags: [Hashtag]?
    /// 読んでいる一覧（`lists`、`followedTags`）。起動したときは、始めたときと前面に出たときの両方で読みに来るため、重ねて読まない。
    private var loadingTabSources: Set<String> = []
    /// アカウントの切り替えなどのメニュー。開くたびに呼んで組み立て直す。
    private let accountMenu: @MainActor () -> UIMenu
    /// 自分で残した投稿の一覧のタブ。ブックマーク、お気に入り。
    private var savedLists: [SavedStatusesController] { [bookmarks, favourites] }
    /// アカウント1つ分の部品（通信、ストリーミング、401の確かめ、電波の回復などのやり直し）と、その決まり。
    private let session: AccountSession
    /// 各タブで共有する、ストリーミングの接続。
    private var streamingHub: StreamingHub { session.streamingHub }
    private let client: MastodonClient
    /// 時間をおく処理の時計。テストでは手で進める時計に差し替える。
    var clock: any Clock<Duration> = AppDependencies.clock
    /// 編集できるかやミュートの期限を決める今の日付。テストでは決まった日付に差し替える。
    var now: () -> Date = AppDependencies.now
    /// このセッションで始めた処理の持ち主。各一覧、開いた画面、投稿欄は、この子の持ち主で処理を始める。
    /// `stop()`で閉じると、開いている画面の数や種類によらず、どれも止まる。
    private let tasks: TaskScope
    #if DEBUG
    /// `scia-debug://notice/progress`で出している、確かめるための処理中のチップを進める。
    private var debugProgressTask: Task<Void, Never>?
    /// `scia-debug://autoscroll`で一覧を動かしている。
    private var debugScrollTicker: FrameTicker?
    /// `scia-debug://autoscroll`で動かしている間に、落ちたフレームを数える。
    private let debugScrollHitches = ScrollHitchMonitor()
    #endif
    /// プロフィールを開く操作の入口。メンション、リンク、自分のプロフィール、ほかのアプリからのURLのどれで開くときも通し、後から押したものだけを開く。
    /// 探すのが長引いたら「取得中」のチップを出す。すぐ見つかったときにチップが一瞬だけ出入りしないよう、出すのは少し待ってから。
    private lazy var profileOpening: LatestLookup = {
        let lookup = LatestLookup(clock: clock) { .seconds(AppDependencies.tuning.value(of: TuningCatalog.profileLookupChipDelay)) }
        lookup.onSlowChange = { [weak self] isSlow in self?.showProfileLookupProgress(isSlow) }
        tasks.onClose { [weak lookup] in lookup?.cancel() }
        return lookup
    }()
    /// ユーザーのメニューのメンションとハンドルのコピーで、相手を探す操作の入口。後から選んだものだけを使う。
    private lazy var identityLookup: LatestLookup = {
        let lookup = LatestLookup(clock: clock) { nil }
        tasks.onClose { [weak lookup] in lookup?.cancel() }
        return lookup
    }()
    /// 引用元の中の引用のように、IDしか分からない投稿のスレッドを開く操作の入口。後から押したものだけを開く。
    private lazy var statusOpening: LatestLookup = {
        let lookup = LatestLookup(clock: clock) { nil }
        tasks.onClose { [weak lookup] in lookup?.cancel() }
        return lookup
    }()
    /// 外から頼まれた画面のうち、編集履歴、メモ、通報、ユーザーのハッシュタグのように、読んでから開く画面の入口。後から頼まれたものだけを開く。
    private lazy var destinationOpening: LatestLookup = {
        let lookup = LatestLookup(clock: clock) { nil }
        tasks.onClose { [weak lookup] in lookup?.cancel() }
        return lookup
    }()
    /// 「接続の状態」画面に出す、このセッションの接続の状態。
    let diagnostics: ConnectionDiagnostics
    private let interactions: StatusInteractions
    private let polls: PollVoting
    /// カードが付く前に受け取った投稿を、見えている間に取り直す。
    private let statusRefresher: StatusRefresher
    /// 「操作の状況」の一覧に並べる、処理の途中と最近の失敗。
    let operationStatus = OperationStatus()
    /// アプリ全体のアプリ内通知。ウインドウごとのチップの列に配る。
    let notices = NoticeCenter()
    /// 届いた通知を、ステータスバーの場所に流す。
    private let statusBarTicker = StatusBarTicker()
    /// 添付ファイルのビューアで、共有や保存のために落とす処理。ビューアを閉じても保存を続ける。
    private lazy var mediaTransfers = MediaTransferCenter(operationStatus: operationStatus, notices: notices)
    /// 一覧で選んだ投稿に、まとめてブーストや共有をする。選んだ一覧を離れても続ける。
    private lazy var batchActions = BatchActionCenter(
        interactions: interactions,
        notices: notices,
        operationStatus: operationStatus,
        tasks: tasks,
        clock: clock,
        fetch: { url, onProgress in try await AppDependencies.mediaDownloads.fileForSharing(for: url, onProgress: onProgress) }
    ) { [weak self] error in
        await self?.failureReason(for: error) ?? ErrorPresentation(error)
    }
    /// APIが401を返したときに、トークンが本当に無効かを確かめる。
    private var authorization: AuthorizationCheck { session.authorization }
    private let onReauthenticate: (SessionController) async -> Void
    /// ログインし直しの途中。続けて押されても、認可画面を重ねて出さない。
    private var isReauthenticating = false
    private let tabBarDelegate: TabReselectionDelegate
    /// タブバーと切り替えタブ。設定のタブの並びから組む。
    private let tabs: TabArrangement
    /// `start()`を呼んだ。それより前に並びが変わっても、ホームと通知を読み始めない。
    private var hasStarted = false
    /// 画面を移る動きに、チップの列を相乗りさせる。
    private let navigationDelegate = NoticeNavigationDelegate()
    /// 開いているプロフィール画面。投稿への操作の結果を反映するために持つ。閉じたものは自然に消える。
    private let profiles: ProfileRegistry
    /// 開いているスレッドの画面。投稿への操作の結果を反映するために持つ。閉じたものは自然に消える。
    private let threads: ThreadRegistry
    /// 開いている検索の結果。投稿への操作の結果を反映するために持つ。閉じたものは自然に消える。
    private let searches: SearchRegistry
    /// 検索のタブの一番下の画面。
    private let searchRoot = SearchViewController()
    private var cachedMyAccount: Account?
    /// セッションで読んだアカウント。メニューと投稿欄の補完に、メンションされたユーザーのアイコンを出すのに使う。
    /// 補完の口は`init`の中で`self`より先に作るので、それより前に作る。
    private let accounts: AccountCache
    /// 読んだ自分のフィルター。ハッシュタグのメニューの「ミュート」を、メニューを組むときに決めるのに使う。
    private let serverFilters: ServerFilterCache
    /// 自分の注目のハッシュタグ。ハッシュタグのメニューの「プロフィールで紹介する」と、投稿欄のハッシュタグの補完で同じものを使う。
    private let ownFeaturedTags: LatestValueCache<[FeaturedTag]>
    /// 補完の候補を読む口。投稿欄とプロフィールの編集で使う。
    private let completionSources: ComposeCompletion.Sources
    /// 補完で読めたカスタム絵文字の一覧。開くたびに補完を作るプロフィールの編集に渡し、読み直さずに並べる。
    private let customEmojis: CustomEmojiCache
    /// タブバーの上の投稿欄。ホームと通知のどちらでも同じ下書きを使う。
    private let composer: InlineComposeController
    /// 書き始めたときに始めた、サーバーの上限と既定の公開範囲などの読み込み。共有されたメディアを、読み終えてから足すのに使う。
    private var composeDefaultsTask: Task<Void, Never>?
    /// 画面のどこにドロップした画像や動画でも、投稿欄に添付する受け口。
    private let mediaDrop = MediaDropTarget()
    /// 状態や設定をそろえる一覧。ホームと通知に加え、開いているプロフィールの一覧も入る。閉じたものは自然に消える。
    private let timelines = NSHashTable<TimelineViewController>.weakObjects()
    /// タブごとの画面を積むナビゲーション。投稿欄のカプセルなどが覆う高さを配る。
    private let contentNavigations = NSHashTable<ContentNavigationController>.weakObjects()
    /// 開いている編集履歴。添付ファイルを開いた・隠した選択を一覧とそろえるために持つ。閉じたものは自然に消える。
    private let editHistories = NSHashTable<EditHistoryViewController>.weakObjects()
    /// 添付ファイルを覆うか。ホームと通知とプロフィールでそろえ、閉じて開き直したプロフィールにも引き継ぐ。
    private var mediaCovers = MediaCovers()
    /// 「続きを読む」で広げた本文。どの一覧で広げても、開いている一覧と、あとで開く一覧にそろえる。
    private var longBodyExpansion = LongBodyExpansion()
    /// 引用元の、受け取ったあとの編集、削除、ミュート、ブロック。どの一覧の囲みにも当て、開き直した画面にも引き継ぐ。
    private var quoteSources = QuoteSourceChanges()
    /// fxtwitterから読んだXの投稿。ホームと通知とプロフィールで同じ投稿を1回だけ読む。
    /// 一覧で見えている画像の先読み。ログアウトしたら、セッションの持ち主と一緒に止める。
    private lazy var mediaPrefetcher = MediaPrefetcher(scope: tasks, store: AppDependencies.mediaImages, network: AppDependencies.network, settings: AppDependencies.settings)
    private let xPosts = XPostStore(client: XPostClient(client: AppDependencies.http), retryPolicy: { TuningCatalog.imageRetry(in: AppDependencies.tuning) })
    private var composerObscuredHeight: CGFloat = 0
    /// 本文のリンクを開くアプリ内のSafari。シートが覆っている高さも、投稿欄と同じく積んだ画面の下の余白にする。
    private let browser = InAppBrowser()
    private var browserObscuredHeight: CGFloat = 0
    private var browserCoversTimelines = false
    /// アプリ内のSafariの高さを選ぶシートが覆っている高さ。
    private var heightPickerObscuredHeight: CGFloat = 0
    /// 出ている設定の画面の数。設定の画面の上に、URLで設定の画面をもう1枚重ねることがある。
    private var shownSettingsCount = 0
    /// 積んだ画面の下を覆っている高さ。投稿欄、アプリ内のSafariのシート、その高さを選ぶシートのうち、いちばん高いもの。
    private var obscuredBottomHeight: CGFloat { max(composerObscuredHeight, browserObscuredHeight, heightPickerObscuredHeight) }
    private let logger = SciaLog.logger(category: "session")

    /// - Parameters:
    ///   - accountMenu: アカウントの切り替えなどのメニュー。開くたびに呼んで組み立て直す。
    ///   - onReauthenticate: トークンが無効なアカウントで、ログインし直しのボタンが押されたときに呼ぶ。ログインし直しが終わるか、取り消されたら返る。
    init(credential: Credential, accountMenu: @escaping @MainActor () -> UIMenu, onReauthenticate: @escaping (SessionController) async -> Void) {
        self.credential = credential
        self.onReauthenticate = onReauthenticate
        self.accountMenu = accountMenu
        let tuning = AppDependencies.tuning
        #if DEBUG
        let session = AccountSession(
            credential: credential,
            transport: BurstMonitoringTransport(base: FaultInjectingTransport(base: ScenarioMode.server?.transport ?? URLSessionTransport()), monitor: RequestBurstLog.monitor),
            connector: FaultInjectingWebSocketConnector(base: ScenarioMode.server?.connector ?? URLSessionWebSocketConnector()),
            // デバッグ版でだけ応答の本文も残す。
            requestLog: RequestLog(includesBody: true),
            tuning: tuning
        )
        #else
        let session = AccountSession(
            credential: credential,
            transport: BurstMonitoringTransport(base: URLSessionTransport(), monitor: RequestBurstLog.monitor),
            connector: URLSessionWebSocketConnector(),
            tuning: tuning
        )
        #endif
        self.session = session
        let tasks = session.tasks
        self.tasks = tasks
        let client = session.client
        let streamingHub = session.streamingHub
        let reportUnauthorizedToSession = { [weak session] in session?.reportUnauthorized() }
        let home = FeedTimelineController(feed: .home, session: session)
        let local = FeedTimelineController(feed: .local, session: session)
        let federated = FeedTimelineController(feed: .federated, session: session)
        let notifications = NotificationsController(session: session)
        let bookmarks = SavedStatusesController(kind: .bookmarks, session: session)
        let favourites = SavedStatusesController(kind: .favourites, session: session)
        // 自分のアカウントを読むのはselfなので、作り終えてからつなぐ。
        let myAccountReference = SessionReference()
        let scheduled = ScheduledStatusesController(client: client, tasks: tasks.child(), myAccount: {
            guard let session = myAccountReference.session else { throw CancellationError() }
            return try await session.myAccount()
        }) { reportUnauthorizedToSession() }
        let serverFeeds = ServerFeedRegistry { [weak session] item in
            guard let session else { return nil }
            return switch item {
            case .list(let id, let title):
                FeedTimelineController(feed: .list(id: id), texts: .list(title: title), session: session)
            case .hashtag(let name):
                FeedTimelineController(feed: .hashtag(name: name), texts: .hashtag(name: name), session: session)
            case .accountHashtag(let accountID, let acct, let name, _):
                FeedTimelineController(feed: .accountHashtag(accountID: accountID, name: name), texts: .accountHashtag(name: name, acct: acct), session: session)
            case .home, .local, .federated, .notifications, .search, .bookmarks, .favourites, .scheduled, .profile:
                nil
            }
        }
        self.serverFeeds = serverFeeds
        let profileTabs = ProfileTabRegistry { [weak tasks] item in
            guard let tasks, case .profile(let accountID, let acct, _) = item else { return nil }
            let scope = tasks.child()
            let loading = ProfileTabLoadingViewController(title: "@\(acct)", tasks: scope) { try await client.account(accountID) }
            return (loading, scope)
        }
        self.profileTabs = profileTabs
        let profileTabIcons = ProfileTabIcons(settings: AppDependencies.settings)
        self.profileTabIcons = profileTabIcons
        self.bookmarks = bookmarks
        self.favourites = favourites
        self.scheduled = scheduled
        self.home = home
        self.local = local
        self.federated = federated
        // ローカルと連合は、起動のたびの通信と購読を増やさないよう、初めて開いたときに読み始める。
        // ホームと通知も、無効にしていて起動のときに始めなかったら、開いたときに始める。
        for feed in [home, local, federated] {
            feed.viewController.onAppearing = { [weak feed] in feed?.startIfNeeded() }
        }
        notifications.viewController.onAppearing = { [weak notifications] in notifications?.startIfNeeded() }
        self.notifications = notifications
        notificationPolicy = NotificationPolicyModel(client: client, tasks: tasks.child()) { reportUnauthorizedToSession() }
        announcements = AnnouncementsModel(operations: AnnouncementsModel.Operations(client: client), streamingHub: streamingHub, tasks: tasks.child()) { reportUnauthorizedToSession() }
        let mediaFormats = UnprocessableMediaFormats(defaults: .standard, instance: credential.instance)
        let diagnostics = ConnectionDiagnostics(rateLimit: session.rateLimit, features: session.features, requestLog: session.requestLog, mediaFormats: mediaFormats)
        self.diagnostics = diagnostics
        // コントローラーはHubを持っているので、弱く持って循環させない。
        let pushedFeeds = PushedFeedRegistry()
        self.pushedFeeds = pushedFeeds
        streamingHub.onChange = { [weak streamingHub, weak home, weak local, weak federated, weak notifications, weak serverFeeds, weak pushedFeeds] in
            guard let streamingHub else { return }
            diagnostics.setStreaming(streamingHub.state, subscriptions: streamingHub.subscriptions)
            for feed in [home, local, federated] + (serverFeeds?.controllers ?? []) + (pushedFeeds?.controllers ?? []) {
                feed?.showStreamingState(streamingHub.state)
            }
            notifications?.showStreamingState(streamingHub.state)
        }
        self.client = client
        let profiles = ProfileRegistry(relationships: RelationshipCache { [client] ids in try await client.relationships(ids) })
        self.profiles = profiles
        let threads = ThreadRegistry()
        self.threads = threads
        let searches = SearchRegistry()
        self.searches = searches
        // 同じ投稿がいくつものタブと開いているプロフィールやスレッドにあることがあるため、どれにも反映する。
        interactions = StatusInteractions(operations: .init(client: client)) { id, transform in
            home.updateStatus(id, transform)
            local.updateStatus(id, transform)
            federated.updateStatus(id, transform)
            notifications.updateStatus(id, transform)
            bookmarks.updateStatus(id, transform)
            favourites.updateStatus(id, transform)
            serverFeeds.updateStatus(id, transform)
            pushedFeeds.updateStatus(id, transform)
            profiles.updateStatus(id, transform)
            threads.updateStatus(id, transform)
            searches.updateStatus(id, transform)
        }
        // 付けた投稿は、サーバーが受け付けたところでブックマークやお気に入りの一覧の先頭に入れる。外したときは行を残す。
        interactions.onSettle = { action, status in
            bookmarks.statusDidSettle(action, status)
            favourites.statusDidSettle(action, status)
        }
        polls = PollVoting(operations: Self.pollOperations(client: client)) { id, transform in
            home.updateStatus(id, transform)
            local.updateStatus(id, transform)
            federated.updateStatus(id, transform)
            notifications.updateStatus(id, transform)
            bookmarks.updateStatus(id, transform)
            favourites.updateStatus(id, transform)
            serverFeeds.updateStatus(id, transform)
            pushedFeeds.updateStatus(id, transform)
            profiles.updateStatus(id, transform)
            threads.updateStatus(id, transform)
            searches.updateStatus(id, transform)
        }
        let timelines = timelines
        let statusRefresher = StatusRefresher(client: client) { refetched in
            let shown = timelines.allObjects
            for timeline in shown { timeline.refreshedStatusID = refetched.id }
            defer { for timeline in shown { timeline.refreshedStatusID = nil } }
            for update in [home.updateStatus, local.updateStatus, federated.updateStatus, notifications.updateStatus, bookmarks.updateStatus, favourites.updateStatus, serverFeeds.updateStatus, pushedFeeds.updateStatus, profiles.updateStatus, threads.updateStatus, searches.updateStatus] {
                update(refetched.id) { $0.adoptingRefreshed(of: refetched) }
            }
        }
        self.statusRefresher = statusRefresher
        // セッションを閉じたら、取り直している途中でも止める。前のアカウントのトークンで取り直し続けないため。
        tasks.onClose { [weak statusRefresher] in statusRefresher?.stop() }

        let homeNavigation = ContentNavigationController(rootViewController: home.viewController)
        let localNavigation = ContentNavigationController(rootViewController: local.viewController)
        let federatedNavigation = ContentNavigationController(rootViewController: federated.viewController)
        let notificationsNavigation = ContentNavigationController(rootViewController: notifications.viewController)
        let bookmarksNavigation = ContentNavigationController(rootViewController: bookmarks.viewController)
        let favouritesNavigation = ContentNavigationController(rootViewController: favourites.viewController)
        let scheduledNavigation = ContentNavigationController(rootViewController: scheduled.viewController)
        let searchNavigation = ContentNavigationController(rootViewController: searchRoot)
        let tabs = TabArrangement(
            navigation: { item in
                switch item {
                case .home: homeNavigation
                case .local: localNavigation
                case .federated: federatedNavigation
                case .notifications: notificationsNavigation
                case .bookmarks: bookmarksNavigation
                case .favourites: favouritesNavigation
                case .scheduled: scheduledNavigation
                case .search: searchNavigation
                case .list, .hashtag, .accountHashtag: serverFeeds.navigation(for: item)
                case .profile: profileTabs.navigation(for: item)
                }
            },
            layout: AppDependencies.settings.tabLayout(for: credential.handle),
            restoring: AppDependencies.settings.switchTabItem(for: credential.handle)
        )
        tabs.onSwitchSelectionChange = { [handle = credential.handle] item in
            AppDependencies.settings.setSwitchTabItem(item, for: handle)
        }
        // 最後に見ていたタブから開く。その項目を無効にしていたら、先頭のタブのままにする。
        if let shown = AppDependencies.settings.shownTabItem(for: credential.handle) {
            tabs.show(shown)
        }
        tabs.icon = { [profileTabIcons] in profileTabIcons.icon(for: $0) }
        profileTabIcons.onChange = { [weak tabs] in tabs?.refreshIcons() }
        self.tabs = tabs
        let tabBarController = tabs.tabBarController
        notifications.onUnreadCountChange = { [weak tabs] count, isLowerBound in
            tabs?.setNotificationsBadge(count == 0 ? nil : isLowerBound ? "\(count)+" : "\(count)")
        }
        let scrollToTop = { (navigation: UINavigationController) -> Void in
            TimelineViewController.shown(in: navigation.viewControllers.first)?.scrollToNewest()
        }
        tabBarDelegate = TabReselectionDelegate(scrollToTop: scrollToTop, navigation: { [weak tabs] in tabs?.navigation(for: $0) }) { tabBarController in
            // タブの切り替えには画面の移り変わりの動きがないため、チップだけを短く動かす。
            tabBarController.noticeOverlay?.follow(nil)
        }
        tabBarController.delegate = tabBarDelegate
        // トークンの失効は、どのAPIで分かっても同じくログインし直しを促す。
        let reportIfUnauthorized = { (error: any Error) in
            if let error = error as? MastodonAPIError, error.isUnauthorized {
                reportUnauthorizedToSession()
            }
        }
        let media = ComposeMediaService<UIImage>(
            upload: { upload in
                do {
                    #if DEBUG
                    if let delay = DebugFaults.slowUploadDelay {
                        try await AppDependencies.clock.sleep(for: delay)
                    }
                    #endif
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
            makeThumbnail: { file in await LocalMediaThumbnail.make(for: file, maxPixelSize: ComposeAttachmentStrip.thumbnailPixelSize) },
            // 版を読めていないときは、版の分からないサーバーとして覚える。版を読めたあとは、もう一度試す。
            unprocessableImageTypes: { mediaFormats.mimeTypes(serverVersion: diagnostics.serverVersion) },
            recordUnprocessableImageType: { mimeType in mediaFormats.record(mimeType, serverVersion: diagnostics.serverVersion) },
            preparation: {
                let settings = AppDependencies.settings
                return MediaPreparationSettings(
                    imageSize: settings.imageUploadSize,
                    videoSize: settings.videoUploadSize,
                    imageQuality: tuning.value(of: TuningCatalog.mediaImageQuality),
                    videoQuality: TuningCatalog.videoQuality(in: tuning),
                    exportProgressShare: tuning.value(of: TuningCatalog.mediaExportProgressShare)
                )
            }
        )
        let redraft = ComposeRedraftService(
            // 新しい投稿に付け直すので、添付は残して削除する。
            deleteStatus: { id in
                do {
                    try await client.deleteStatus(id, deleteMedia: false)
                } catch {
                    reportIfUnauthorized(error)
                    throw error
                }
            },
            waitUntilReleased: { id in
                do {
                    return try await client.waitUntilReleased(id)
                } catch {
                    reportIfUnauthorized(error)
                    throw error
                }
            }
        )
        // 補完の検索は別のスレッドから呼ばれるため、ほかのAPIと同じ知らせ方を、隔離されたAuthorizationCheckに直接送る。
        let reportCompletionFailure: @Sendable (any Error) async -> Void = { [authorization = session.authorization] error in
            guard let error = error as? MastodonAPIError, error.isUnauthorized else { return }
            _ = await authorization.reportUnauthorized()
        }
        let accounts = AccountCache { [client] ids in try await client.accounts(ids) }
        self.accounts = accounts
        serverFilters = ServerFilterCache(label: "filters") { [client] in try await client.filters() }
        let ownFeaturedTags = LatestValueCache<[FeaturedTag]>(label: "featuredTags") { [client] in try await client.featuredTags() }
        self.ownFeaturedTags = ownFeaturedTags
        // キャッシュが自分で始めた通信も、ログアウトやアカウントの切り替えで止める。
        tasks.onClose { [weak accounts, weak serverFilters, weak ownFeaturedTags, weak relationships = profiles.relationships] in
            accounts?.close()
            serverFilters?.close()
            ownFeaturedTags?.close()
            relationships?.close()
        }
        let customEmojis = CustomEmojiCache()
        self.customEmojis = customEmojis
        completionSources = ComposeCompletion.Sources(
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
                    // 補完が読むのは、まだ持っていないか、前に読めなかったときだけなので、そのたびに読み直す。
                    await ownFeaturedTags.refresh(purpose: .display)
                    return try await ownFeaturedTags.latest()
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
            },
            // 読めなかった人は返らないだけで、失敗はAccountCacheがログに残す。
            accounts: { ids in await Array(accounts.load(ids).values) }
        ).remembering(customEmojisIn: customEmojis)
        // 投稿欄は初期化の途中で作るため、編集した投稿を引用の囲みに当てる先は、初期化を終えてからつなぐ。
        let editedStatuses = SessionReference()
        // 予約できたことのチップを出す先も、初期化を終えてからつなぐ。
        let schedules = SessionReference()
        composer = InlineComposeController(
            model: ComposeModel<UIImage>(tasks: tasks.child(), myAccountID: credential.accountID, media: media, redraft: redraft, backgroundTime: BackgroundTime.request) { draft in
                do {
                    if let editing = draft.editing {
                        // ストリーミングの編集の知らせを待たずに、どの一覧にも編集したあとの投稿を出す。切れている間も直るようにするため。
                        let edited = try await client.editStatus(editing, to: draft)
                        for update in [home.updateStatus, local.updateStatus, federated.updateStatus, notifications.updateStatus, bookmarks.updateStatus, favourites.updateStatus, serverFeeds.updateStatus, pushedFeeds.updateStatus, profiles.updateStatus, threads.updateStatus, searches.updateStatus] {
                            update(edited.id) { _ in edited }
                        }
                        editedStatuses.session?.changeQuoteSources(.status(edited.id)) { $0.edit(edited) }
                    } else if let scheduledAt = draft.scheduledAt {
                        let scheduledStatus = try await client.scheduleStatus(draft, at: scheduledAt)
                        schedules.session?.didSchedule(scheduledStatus)
                    } else {
                        // ストリーミングで届くまで数秒かかることがあるため、応答の投稿をすぐホームと、返信先を開いているスレッドに出す。
                        let posted = try await client.postStatus(draft)
                        home.receivePosted(posted)
                        threads.receivePosted(posted)
                    }
                } catch {
                    reportIfUnauthorized(error)
                    throw error
                }
            },
            completion: ComposeCompletion(sources: completionSources, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning), recentMentions: RecentMentions(defaults: .standard, account: credential.handle)),
            recentEmojis: RecentEmojis(defaults: .standard, instance: credential.instance),
            languages: PostingLanguageSource(recent: RecentPostingLanguages(defaults: .standard, account: credential.handle), load: PostingLanguageCache { try await client.postingLanguages() }.languages)
        )
        rootViewController = tabBarController
        prepare(searchRoot)
        tabBarController.view.addInteraction(UIDropInteraction(delegate: mediaDrop))
        // ペーストと同じく、書きかけの下書きがあっても聞かずに後ろに足す。
        mediaDrop.onDrop = { [weak self] drop in self?.receiveDroppedMedia(drop) }
        composer.model.onMediaReduced = { [weak self] kind in
            self?.notices.showTransient(.mediaReduced(kind), duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
        }
        // 添付しなかったことは失敗に近く、文も長いので、失敗と同じ時間だけ出す。
        composer.model.onPastedMediaSkipped = { [weak self] kinds in
            self?.notices.showTransient(.pastedMediaSkipped(kinds), duration: tuning.value(of: TuningCatalog.noticeFailureChipDuration))
        }
        composer.onLinkTitleLoadingChange = { [weak self] in self?.linkTitleActivityDidChange() }
        composer.onLinkTitleFailed = { [weak self] failure in self?.linkTitleDidFail(failure) }
        session.onCredentialsInvalid = { [weak self] in self?.credentialsDidBecomeInvalid() }
        session.onPreferencesLoad = { [weak self] preferences in
            for timeline in self?.timelines.allObjects ?? [] {
                timeline.spoilerExpansion.expandsByDefault = preferences.expandsSpoilers
            }
        }
        for viewController in [home.viewController, local.viewController, federated.viewController, notifications.viewController, bookmarks.viewController, favourites.viewController] {
            configureTabRoot(viewController)
        }
        // 並びにあるリストとハッシュタグは、タブを組んだときに作ってある。それ以後に作るものも、ここで同じように整える。
        serverFeeds.onCreate = { [weak self] item, controller, navigation in
            self?.configureServerFeed(controller, for: item, in: navigation)
        }
        profileTabs.onCreate = { [weak self] item, loading, navigation in
            self?.configureProfileTab(loading, for: item, in: navigation)
        }
        composer.onBeginEditing = { [weak self] in
            self?.applyComposeDefaults()
            // アプリ内のSafariのシートは投稿欄より手前に出るため、書いている間は伏せた高さまで下げる。
            self?.browser.lowerForCompose()
        }
        composer.onEndEditing = { [weak self] in self?.browser.restoreAfterCompose() }
        composer.onOpenWithoutEditing = { [weak self] in self?.applyComposeDefaults() }
        composer.presenterAboveInlineCompose = { [weak tabBarController] in
            // 投稿欄より手前にあるのは、アプリ内のSafariのシートだけのとき。ほかの画面を出していれば、その上には重ねない。
            guard let tabBarController else { return nil }
            let top = tabBarController.frontmostPresented
            return top === tabBarController || top is SFSafariViewController ? top : nil
        }
        composer.onShowReplyTarget = { [weak tabs] status in
            // 今見えている一覧（ホーム、通知、開いているプロフィール）に返信先があれば、そこへ戻る。なければ動かさない。
            let navigation = tabs?.selectedNavigation
            TimelineViewController.shown(in: navigation?.topViewController)?.scrollToStatus(status.id, displayedID: status.displayed.id)
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
        browser.onPresenceChange = { [weak self] _ in self?.applyShowsFocusInlineCompose() }
        browser.onCoverageChange = { [weak self] covered in
            guard let self else { return }
            browserCoversTimelines = covered
            for timeline in timelines.allObjects {
                timeline.setCoveredByInAppBrowser(covered)
            }
        }
        notices.showOperationStatus = { [weak self] presenter in self?.showOperationStatus(from: presenter) }
        editedStatuses.session = self
        schedules.session = self
        myAccountReference.session = self
        scheduled.viewController.mediaTransfers = mediaTransfers
        scheduled.viewController.notices = notices
        composer.model.onScheduleRewritten = { [weak self] id in self?.cancelRewrittenSchedule(id) }
        composer.model.onRedraftDeleted = { [weak self] id in self?.removeDeletedStatus(id) }
        composer.onShowScheduledStatuses = { [weak self] in self?.showScheduledStatuses() }
        scheduled.onRewrite = { [weak self] status in self?.confirmRewriting(status) }
        installAccountButton(on: scheduled.viewController)
        installNotificationRequests()
        installAccountButton(on: searchRoot)
        announcements.onUnreadCountChange = { [weak self] _ in self?.updateAccountBadges() }
        announcements.onReactionFailure = { [weak self] error in self?.reportAnnouncementReactionFailure(error) }
        streamingHub.onEvent = { [weak self] event in
            switch event {
            case .statusUpdate(let edited): self?.changeQuoteSources(.status(edited.id)) { $0.edit(edited) }
            case .delete(let id):
                self?.changeQuoteSources(.status(id)) { $0.delete(id) }
                // 書き直している元の投稿がほかの端末で消えたら、やめる前に確かめるようにする。
                self?.composer.model.redraftedStatusWasDeleted(id, stopsRedrafting: false)
            case .update, .notification, .filtersChanged, .notificationsMerged, .announcement, .announcementReaction, .announcementDelete, .unhandled: break
            }
        }
        xPosts.onLoad = { [weak self] id in
            for timeline in self?.timelines.allObjects ?? [] {
                timeline.applyXPost(id: id)
            }
        }
        configureStatusBarTicker(tabBarController: tabBarController)
        for navigation in [homeNavigation, localNavigation, federatedNavigation, notificationsNavigation, bookmarksNavigation, favouritesNavigation, scheduledNavigation, searchNavigation] {
            configure(navigation, scrollToTop: scrollToTop)
        }
        tabs.onPlacementChange = { [weak self] in self?.applyEnabledItems($0) }
        applyEnabledItems(tabs.placement)
        observeTabLayout()
        observeHidesEmptyComposeBar()
        // 投稿欄を置くとタブバーの画面を読み込むため、各一覧の設定を終えてから置く。
        composer.install(in: tabBarController)
    }

    /// 設定でオフにしている間、この機種で使えない間、通知タブを見ている間、ビューアのように画面全体を覆う画面を出している間は流さない。
    /// 押すと通知タブを開く。投稿を1件だけ開く画面がまだないため。
    /// 設定でタブの並びを変えたら、タブバーを組み直し、無効にした項目の購読をやめ、有効にした項目の購読を戻す。
    private func observeTabLayout() {
        let handle = credential.handle
        withObservationTracking {
            _ = AppDependencies.settings.tabLayout(for: handle)
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor [weak self] in
                guard let self, !tasks.isClosed else { return }
                // 最初の並びに戻したら、リストが消えるので足し直す。足し直した変更は、もう一度ここへ来て反映する。
                addMissingServerItemsToTabLayout()
                let layout = AppDependencies.settings.tabLayout(for: handle)
                // ユーザーのハッシュタグとプロフィールは、「タブから外す」で並びから外したら、一覧を止めて捨てる。
                let userAdded = Set(Self.userAddedItems(in: layout))
                tabs.forget(serverFeeds.removeAll(where: \.isAccountHashtag, except: userAdded))
                tabs.forget(profileTabs.removeAll(except: userAdded))
                profileTabIcons.removeAvatars(except: Set(userAdded.compactMap { item in
                    if case .profile(let accountID, _, _) = item { accountID } else { nil }
                }))
                tabs.apply(layout)
                observeTabLayout()
            }
        }
    }

    /// 並びに合わせて、無効にした項目の購読をやめ、有効にした項目の購読を戻す。
    /// 起動のあとに有効にしたホームと通知は、ここで読み始める。ローカルと連合は、開いたときに読み始める。
    private func applyEnabledItems(_ placement: TabPlacement) {
        for feed in tabFeeds {
            feed.setEnabled(placement.location(of: TabItem(feed.feed)) != .disabled)
        }
        notifications.setEnabled(placement.location(of: .notifications) != .disabled)
        // 見せていた一覧を無効にしたら、UIKitが選んだ先頭のタブへ移り、見せなくなる。
        applyShownSavedLists()
        guard hasStarted else { return }
        loadProfileTabIcons(placement)
        if placement.location(of: .home) != .disabled {
            home.startIfNeeded()
        }
        if placement.location(of: .notifications) != .disabled {
            notifications.startIfNeeded()
        }
    }

    /// ブックマークとお気に入りの一覧に、タブで見せているかを伝える。見せ始めたら最新の分を読み、見せなくなったら外した行を消す。
    /// 上にスレッドやビューアを重ねても、タブで見せていることは変わらないので、消さない。
    private func applyShownSavedLists() {
        for list in savedLists {
            list.setShown(tabs.isShowing(TabItem(list.kind)))
        }
    }

    /// 見ているタブの項目を、次に起動したときに開けるよう覚えておく。
    private func rememberShownTab() {
        guard let item = tabs.shownItem else { return }
        AppDependencies.settings.setShownTabItem(item, for: credential.handle)
    }

    private func configureStatusBarTicker(tabBarController: UITabBarController) {
        let ticker = statusBarTicker
        ticker.scene = { [weak tabBarController] in tabBarController?.view.window?.windowScene }
        ticker.rootController = { [weak tabBarController] in tabBarController }
        ticker.canShow = { [weak tabBarController, weak tabs] in
            guard AppDependencies.settings.showsStatusBarTicker, StatusBarCutout.isAvailable else { return false }
            guard let tabBarController, let tabs, !tabs.isShowing(.notifications) else { return false }
            // ビューアの上に代替テキストのシートを重ねたときのように、手前がシートでも奥に画面全体を覆う画面があれば流さない。
            var presented = tabBarController.presentedViewController
            while let current = presented {
                if [.fullScreen, .overFullScreen, .custom].contains(current.modalPresentationStyle) { return false }
                presented = current.presentedViewController
            }
            return true
        }
        ticker.onTap = { [weak tabs, weak ticker] in
            UserAction.selectTab("notifications").record()
            tabs?.show(.notifications)
            ticker?.clear()
        }
        tabs.onShownItemChange = { [weak self] in
            ticker.reevaluate()
            self?.applyShownSavedLists()
            self?.rememberShownTab()
        }
        notifications.onArrival = { notification, verdict in ticker.receive(notification, verdict: verdict) }
        tabBarDelegate.onSelect = { [weak self] in
            ticker.reevaluate()
            self?.applyShownSavedLists()
            self?.rememberShownTab()
        }
        observeStatusBarTickerSetting()
        #if DEBUG
        for feed in feeds {
            feed.onDummyNotifications = { DummyNotifications.stream(into: ticker) }
            feed.onSetStatusBarTickerLooping = { [weak ticker] isOn in ticker?.setLooping(isOn, items: DummyNotifications.samples) }
            feed.isStatusBarTickerLooping = { [weak ticker] in ticker?.isLooping ?? false }
        }
        #endif
    }


    /// 設定でステータスバーの通知をオフからオンにしたら、どう出るかが分かるよう、デモの通知を1件流す。
    private func observeStatusBarTickerSetting() {
        let wasOn = AppDependencies.settings.showsStatusBarTicker
        withObservationTracking {
            _ = AppDependencies.settings.showsStatusBarTicker
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                guard let self, !self.tasks.isClosed else { return }
                if !wasOn, AppDependencies.settings.showsStatusBarTicker {
                    self.showStatusBarTickerDemo()
                }
                self.observeStatusBarTickerSetting()
            }
        }
    }

    /// デモの通知。差出人は自分のアカウントにし、実物の通知と同じくアイコンと名前を出す。
    private func showStatusBarTickerDemo() {
        tasks.run(.action) { [weak self] in
            guard let self else { return }
            do {
                let account = try await myAccount()
                statusBarTicker.receive(StatusBarTickerItem(id: "demo", kind: .favourite, account: account, subject: .text(RichText.plain("通知はここに流れます", emojis: []))))
            } catch {
                logger.info("statusBarTicker demo skipped: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 右上の投稿欄で書き始めるボタンは、投稿欄に触れられないときに出す。アプリ内のSafariのシートの裏に隠れている間と、設定で空の投稿欄を隠している間。
    /// 設定で隠しているときは、下書きがあって投稿欄が見えていても出したままにする。下書きの有無でボタンが出たり消えたりしないようにするため。
    private var showsFocusInlineCompose: Bool {
        browser.isPresented || AppDependencies.settings.hidesEmptyComposeBar
    }

    private func applyShowsFocusInlineCompose() {
        for timeline in timelines.allObjects {
            timeline.setShowsFocusInlineCompose(showsFocusInlineCompose)
        }
    }

    private func observeHidesEmptyComposeBar() {
        withObservationTracking {
            _ = AppDependencies.settings.hidesEmptyComposeBar
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                guard let self, !self.tasks.isClosed else { return }
                self.applyShowsFocusInlineCompose()
                self.observeHidesEmptyComposeBar()
            }
        }
    }

    private func applyObscuredBottomHeight() {
        for navigation in contentNavigations.allObjects {
            navigation.coveredBottomHeight = obscuredBottomHeight
        }
    }

    /// タブの一番下の画面の一覧に、アカウントのボタンを置き、投稿への操作とプロフィールを開けるようにする。
    private func configureTabRoot(_ viewController: TimelineViewController) {
        installAccountButton(on: viewController)
        #if DEBUG
        viewController.onDebugURL = { [weak self] url in self?.handle(url) }
        #endif
        configure(viewController)
    }

    /// タブの根の画面の左上に、アカウントのボタンを置く。
    private func installAccountButton(on viewController: UIViewController) {
        let accountMenu = accountMenu
        viewController.navigationItem.leftBarButtonItem = Self.accountButton(for: credential) { [weak self, weak viewController] in
            let myProfile = UIAction(title: "自分のプロフィール", image: UIImage(systemName: "person.crop.circle")) { _ in
                guard let viewController else { return }
                self?.openMyProfile(from: viewController)
            }
            let recent = UIAction(title: "操作の状況", image: UIImage(systemName: "list.bullet.clipboard")) { _ in
                self?.showOperationStatus()
            }
            // サーバー上のアカウントの設定なので、アプリの設定ではなく、アカウントのメニューから開く。
            let policy = UIAction(title: "通知のフィルタリング", image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { _ in
                self?.showNotificationPolicy()
            }
            // お知らせもサーバーに属するものなので、通知のフィルタリングと同じ並びに置く。
            let unread = self?.announcements.unreadCount ?? 0
            let announcements = UIAction(title: "お知らせ", subtitle: unread > 0 ? "未読\(unread)件" : nil, image: UIImage(systemName: "megaphone")) { _ in
                self?.showAnnouncements()
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: [myProfile, recent, policy, announcements])] + accountMenu().children)
        }
        if let item = viewController.navigationItem.leftBarButtonItem {
            accountButtons.add(item)
            applyAccountBadge(to: item)
        }
    }

    /// 未読のお知らせがあれば、アカウントのボタンに点を付ける。
    private func updateAccountBadges() {
        for item in accountButtons.allObjects {
            applyAccountBadge(to: item)
        }
    }

    private func applyAccountBadge(to item: UIBarButtonItem) {
        let unread = announcements.unreadCount
        item.badge = unread > 0 ? .indicator() : nil
        item.accessibilityHint = unread > 0 ? "未読のお知らせが\(unread)件あります。" : nil
    }

    /// タブのナビゲーションで、チップの列を画面の移り変わりに合わせ、Macでバーの空いたところを押したら一覧を最上部へ動かす。
    /// 積んだどの画面でも、投稿欄のカプセルなどが覆う下端を空ける。
    private func configure(_ navigation: ContentNavigationController, scrollToTop: @escaping (UINavigationController) -> Void) {
        navigation.delegate = navigationDelegate
        contentNavigations.add(navigation)
        navigation.coveredBottomHeight = obscuredBottomHeight
        // 奥の画面を開いているときは、その画面の上のバーなので、一覧は動かさない。
        navigation.onEmptyBarClickOnMac = { [weak navigation] in
            guard let navigation, navigation.viewControllers.count == 1 else { return }
            scrollToTop(navigation)
        }
    }

    /// 並びに出たリストやハッシュタグの一覧を、ホームやローカルと同じように整える。ローカルと同じく、初めて開いたときに読み始める。
    private func configureServerFeed(_ controller: FeedTimelineController, for item: TabItem, in navigation: ContentNavigationController) {
        configureTabRoot(controller.viewController)
        if item.isAccountHashtag {
            controller.viewController.screenBarItems = [tabToggleItem(for: item)]
        }
        if case .list(let id, let title) = item {
            controller.viewController.screenBarItems = [listEditor.barItem(listID: id, fallbackTitle: title) { [weak self, weak viewController = controller.viewController] title in
                guard let viewController else { return }
                self?.openListMembers(listID: id, title: title, from: viewController)
            }]
        }
        configure(navigation) { navigation in
            (navigation.viewControllers.first as? TimelineViewController)?.scrollToNewest()
        }
        controller.viewController.onAppearing = { [weak controller] in controller?.startIfNeeded() }
        controller.showStreamingState(streamingHub.state)
        controller.setEnabled(tabs.placement.location(of: TabItem(controller.feed)) != .disabled)
    }

    /// 並びに出たプロフィールのタブを整える。アカウントを読めたら、プロフィール画面に差し替え、前に出ている間は新着を読ませる。
    private func configureProfileTab(_ loading: ProfileTabLoadingViewController, for item: TabItem, in navigation: ContentNavigationController) {
        installAccountButton(on: loading)
        loading.describe = { [weak self] error in await self?.failureReason(for: error) ?? ErrorPresentation(error) }
        configure(navigation) { navigation in
            (navigation.viewControllers.first as? TimelineViewController)?.scrollToNewest()
        }
        loading.onAccount = { [weak self] account in
            self?.loadProfileTabIcon(of: account, for: item)
        }
        loading.onLoad = { [weak self, weak navigation] account in
            guard let self, let navigation, let tasks = profileTabs.tasks(for: item) else { return }
            let (controller, viewController) = makeProfile(account, tasks: tasks.child())
            configureTabRoot(viewController)
            viewController.screenBarItems.append(tabToggleItem(for: item))
            // 切り替えタブの中なら、見出しのメニューで項目を切り替える。タブの並びは一番下の画面に付けているので、差し替える画面に移す。
            viewController.navigationItem.titleMenuProvider = navigation.viewControllers.first?.navigationItem.titleMenuProvider
            controller.readsNewWhileShown()
            // 差し替えると画面が出始めて読み始めるので、その前にバックグラウンドかどうかを伝える。
            profileTabs.setController(controller, for: item)
            // 読んでいる間に奥の画面を積むことはないので、一番下の画面だけを差し替える。
            navigation.setViewControllers([viewController] + navigation.viewControllers.dropFirst(), animated: false)
            controller.start()
        }
    }

    /// 並びに出ているプロフィールのアカウントとアイコンを読む。タブのアイコンに使うので、開くのを待たず、切り替えタブで選んでいなくても読む。
    /// 読めているものは読み直さない。読めなかったものは、並びが変わるたびに読み直す。決まりはdocs/tabs.mdの「プロフィール」にある。
    private func loadProfileTabIcons(_ placement: TabPlacement) {
        for item in placement.tabs + placement.switchable where item.isProfile && !profileTabIcons.hasAvatar(for: item) {
            _ = profileTabs.navigation(for: item)
            profileTabs.loading(for: item)?.loadAccount()
        }
    }

    /// タブに置いたプロフィールの、タブに出すその人のアイコンを読む。読めなければ記号のままにする。
    private func loadProfileTabIcon(of account: Account, for item: TabItem) {
        guard let url = account.avatarStatic, let tasks = profileTabs.tasks(for: item) else { return }
        let key = AvatarView.key(url: url, animates: false, side: ProfileTabIcons.loadSide, scale: tabs.tabBarController.traitCollection.displayScale)
        tasks.run(.display) { [weak self] in
            do {
                let image = try await AppDependencies.avatarImages.image(for: key)
                self?.profileTabIcons.setAvatar(image, forAccountID: account.id)
            } catch {
                self?.logger.error("profile tab icon load failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 自分のリストとフォローしているハッシュタグを読み、タブの並びに反映する。決まりはdocs/tabs.mdの「リスト」と「フォローしているハッシュタグ」にある。
    /// 読めなかった一覧は、並びを変えない。
    private func loadTabSources() {
        let listChangeCount = listChangeCount
        loadTabSource("lists", fetch: { try await $0.lists() }) { session, lists in
            // 読んでいる間にアプリの中で作ったり消したりしていたら、読んだ一覧にはその変更が入っていないことがあり、作ったリストを外したり、消したリストを戻したりしてしまう。
            // 手元はもう変更を入れてあるので、この一覧は使わず、次に起動したときかアプリに戻ったときに読み直す。
            guard session.listChangeCount == listChangeCount else {
                session.logger.info("lists load discarded after local change")
                return
            }
            session.apply(lists: lists)
        }
        loadTabSource("followedTags", fetch: { try await $0.followedTags() }, apply: { $0.apply(hashtags: $1) })
    }

    private func loadTabSource<Value: Sendable>(
        _ name: String,
        fetch: @escaping @Sendable (MastodonClient) async throws -> Value,
        apply: @escaping @MainActor (SessionController, Value) -> Void
    ) {
        guard loadingTabSources.insert(name).inserted else { return }
        let client = client
        tasks.run(.display) { [weak self] in
            defer { self?.loadingTabSources.remove(name) }
            do {
                let value = try await fetch(client)
                guard let self else { return }
                apply(self, value)
            } catch {
                self?.logger.error("\(name, privacy: .public) load failed: \(SciaLog.describe(error), privacy: .public)")
                if let error = error as? MastodonAPIError, error.isUnauthorized {
                    self?.reportUnauthorized()
                }
            }
        }
    }

    /// 読んだリストを並びに反映し、もうないリストの一覧を止める。
    private func apply(lists: [MastodonList]) {
        loadedLists = lists
        logger.info("lists loaded count=\(lists.count, privacy: .public)")
        setTabLayout(AppDependencies.settings.tabLayout(for: credential.handle).syncingLists(lists))
        tabs.forget(serverFeeds.removeAll(where: \.isList, except: Set(lists.map { TabItem.list(id: $0.id, title: $0.title) })))
    }

    /// 読んだハッシュタグを並びに反映し、フォローをやめたハッシュタグの一覧を止める。
    private func apply(hashtags: [Hashtag]) {
        loadedHashtags = hashtags
        logger.info("followed tags loaded count=\(hashtags.count, privacy: .public)")
        setTabLayout(AppDependencies.settings.tabLayout(for: credential.handle).syncingHashtags(hashtags))
        tabs.forget(serverFeeds.removeAll(where: \.isHashtag, except: Set(hashtags.map { TabItem.hashtag(name: $0.name) })))
    }

    /// 最初の並びに戻したときに、直近に読んだリストとハッシュタグを無効のまま足し直す。並びにあるものは外しも書き換えもしない。
    /// ユーザーのハッシュタグは、設定の画面が最初の並びを書くときに残す（`keepingUserAddedItems`）。
    private func addMissingServerItemsToTabLayout() {
        let items = (loadedLists ?? []).map { TabItem.list(id: $0.id, title: $0.title) } + (loadedHashtags ?? []).map { TabItem.hashtag(name: $0.name) }
        setTabLayout(AppDependencies.settings.tabLayout(for: credential.handle).addingMissing(items))
    }

    private static func userAddedItems(in layout: MenuLayout<TabItem>) -> [TabItem] {
        layout.elements.compactMap { element in
            if case .item(let item, _) = element, item.isUserAdded { item } else { nil }
        }
    }

    /// 並びが変わったときだけ保存する。保存すると並びの変化の知らせが来るため、同じ並びを書き続けないようにする。
    private func setTabLayout(_ layout: MenuLayout<TabItem>) {
        guard layout.tokens != AppDependencies.settings.tabLayout(for: credential.handle).tokens else { return }
        AppDependencies.settings.setTabLayout(layout, for: credential.handle)
    }

    /// 一覧から投稿への操作とプロフィールを開けるようにする。プロフィール画面の一覧にも使う。
    private func configure(_ viewController: TimelineViewController) {
        timelines.add(viewController)
        viewController.notices = notices
        if authorization.state == .invalid {
            showReauthenticationPrompt(on: viewController)
        }
        viewController.setCoveredByInAppBrowser(browserCoversTimelines)
        viewController.holdsSettingsChanges = shownSettingsCount > 0
        viewController.onFocusInlineCompose = { [weak self] in self?.composer.beginEditing() }
        viewController.setShowsFocusInlineCompose(showsFocusInlineCompose)
        viewController.myAccountID = credential.accountID
        viewController.spoilerExpansion.expandsByDefault = session.preferences?.expandsSpoilers ?? false
        viewController.mediaCovers = mediaCovers
        viewController.quoteSourceChanges = quoteSources
        viewController.xPosts = xPosts
        viewController.mediaPrefetcher = mediaPrefetcher
        viewController.onChangeMediaCovers = { [weak self, weak viewController] covers, status in
            self?.shareMediaCovers(covers, changed: status, from: viewController)
        }
        viewController.longBodyExpansion = longBodyExpansion
        viewController.onChangeLongBodyExpansion = { [weak self, weak viewController] expansion, key in
            self?.shareLongBodyExpansion(expansion, changed: key, from: viewController)
        }
        viewController.onStatusAction = { [weak self, weak viewController] action, status in self?.perform(action, on: status, from: viewController) }
        viewController.onPostSelectionChange = { [weak self] isSelecting in self?.composer.yieldsToToolbar = isSelecting }
        viewController.onBatchReblog = { [weak self] statuses in
            guard let self else { return }
            batchActions.reblog(statuses, myAccountID: credential.accountID, visibility: AppDependencies.settings.reblogVisibility)
        }
        viewController.onBatchShare = { [weak self] statuses in self?.batchActions.share(statuses) }
        viewController.onFollowRequestDecision = { [weak self] decision, request in self?.answerFollowRequest(decision, to: request) }
        viewController.onVote = { [weak self, weak viewController] choices, status in
            guard let viewController else { return }
            self?.vote(choices, on: status, from: viewController)
        }
        viewController.onRefreshPoll = { [weak self, weak viewController] status in
            guard let viewController else { return }
            self?.refreshPoll(of: status, from: viewController)
        }
        viewController.onDismissNotification = { [weak self] notification in self?.dismissNotification(notification) }
        viewController.onOpenGroupAccounts = { [weak self, weak viewController] notification in
            guard let viewController else { return }
            self?.openAccountList(of: notification, from: viewController)
        }
        viewController.mediaTransfers = mediaTransfers
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
        viewController.onOpenURL = { [weak self] url, browser in self?.open(url, in: browser) }
        viewController.onOpenProfileURL = { [weak self, weak viewController] url in
            guard let viewController else { return }
            self?.openProfile(resolvingLink: url, from: viewController)
        }
        viewController.onOpenAccountHashtag = { [weak self, weak viewController] name, account in
            guard let viewController else { return }
            self?.openAccountHashtag(name, of: account, from: viewController)
        }
        viewController.onOpenHashtag = { [weak self, weak viewController] name in
            guard let viewController else { return }
            self?.openFeed(.hashtag(name: name), from: viewController)
        }
        viewController.onOpenThread = { [weak self, weak viewController] status, rowFrame in
            guard let viewController else { return }
            self?.openThread(of: status, rowFrame: rowFrame, from: viewController)
        }
        viewController.onOpenStatusID = { [weak self, weak viewController] statusID, rowFrame in
            guard let viewController else { return }
            self?.openThread(statusID: statusID, rowFrame: rowFrame, from: viewController)
        }
        viewController.userMenuActions = userMenuActions
        viewController.hashtagMenuActions = hashtagMenuActions
        viewController.onVisibleUnsettledStatusesChange = { [weak self, weak viewController] statuses in
            guard let self, let viewController else { return }
            #if DEBUG
            // ダミー投稿はサーバーにないため、取り直さない。カードはダミーを流した側が届ける。
            let statuses = statuses.filter { status in !self.feeds.contains { $0.isDebugLocalOnly(status.id) } }
            #endif
            self.statusRefresher.setVisible(statuses, from: viewController)
        }
    }

    /// 一覧や編集履歴で開いたり隠したりした結果を、ほかの一覧と編集履歴にもそろえる。
    private func shareMediaCovers(_ covers: MediaCovers, changed status: Status, from source: AnyObject?) {
        mediaCovers = covers
        for timeline in timelines.allObjects where timeline !== source {
            timeline.applyMediaCovers(covers, changed: status)
        }
        for history in editHistories.allObjects where history !== source {
            history.applyMediaCovers(covers, changed: status)
        }
    }

    /// 一覧で「続きを読む」で広げた本文を、ほかの一覧にもそろえる。
    private func shareLongBodyExpansion(_ expansion: LongBodyExpansion, changed key: LongBodyExpansion.Key, from source: AnyObject?) {
        longBodyExpansion = expansion
        for timeline in timelines.allObjects where timeline !== source {
            timeline.applyLongBodyExpansion(expansion, changed: key)
        }
    }

    /// 引用元の変化を覚え、変わったときだけ、開いている一覧に配る。
    private func changeQuoteSources(_ change: QuoteSourceChange, _ apply: (inout QuoteSourceChanges) -> Void) {
        var changed = quoteSources
        apply(&changed)
        guard changed != quoteSources else { return }
        quoteSources = changed
        for timeline in timelines.allObjects {
            timeline.applyQuoteSourceChanges(changed, affecting: change)
        }
    }

    /// 本文のリンクを開く。URLは設定に応じて既定のブラウザかアプリ内のSafariで、メンションはその人のプロフィールを、ハッシュタグはそのタイムラインを、開いた一覧に積む。
    private func open(_ destination: RichText.LinkDestination, in status: Status, from source: UIViewController) {
        switch destination {
        case .url(let url):
            open(url, in: AppDependencies.settings.linkBrowser.browser(for: url))
        case .mention(let acct, let url):
            // ローカルのacctはドメインを含まず、検索では完全一致にならないため、投稿のメンションの一覧にあるIDで引く。
            guard let mention = status.mentions.first(where: { $0.url == url || $0.acct == acct }) else {
                logger.error("mention not in status acct=\(acct, privacy: .private(mask: .hash))")
                handle(ProfileNotFound(acct: acct), title: "プロフィールを開けませんでした")
                return
            }
            openProfile(accountID: mention.id, from: source)
        case .hashtag(let name, _):
            openFeed(.hashtag(name: name), from: source)
        }
    }

    /// プロフィールの自己紹介や補足情報のリンクを開く。ハッシュタグは、投稿の本文と同じくそのタイムラインを開く。
    /// 自己紹介には投稿のようなメンションの一覧がなく、IDが分からないため、メンションはプロフィールのURLから探す。
    private func open(_ destination: RichText.LinkDestination, inProfileFrom source: UIViewController) {
        switch destination {
        case .url(let url):
            open(url, in: AppDependencies.settings.linkBrowser.browser(for: url))
        case .mention(let acct, let url):
            openProfile(resolving: url, acct: acct, from: source)
        case .hashtag(let name, _):
            openFeed(.hashtag(name: name), from: source)
        }
    }

    // MARK: - ハッシュタグ

    /// ハッシュタグのメニューの「ユーザーの投稿」で、`account`の投稿のうち、ハッシュタグ`name`の付いたものを開いた一覧に積む。
    private func openAccountHashtag(_ name: String, of account: Account, from source: UIViewController) {
        let item = TabItem.accountHashtag(accountID: account.id, acct: account.acct, name: name)
        openFeed(.accountHashtag(accountID: account.id, name: name), texts: .accountHashtag(name: name, acct: account.acct), barItems: [tabToggleItem(for: item)], from: source)
    }

    /// ユーザーのハッシュタグの一覧とプロフィール画面の右上に置く、タブの並びに足すか外すボタン。並びは開いている間にも変わるので、メニューを開くたびに並びを見て中身を決める。
    /// 決まりはdocs/tabs.mdの「ユーザーのハッシュタグ」と「プロフィール」にある。
    private func tabToggleItem(for item: TabItem) -> UIBarButtonItem {
        let handle = credential.handle
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            let layout = AppDependencies.settings.tabLayout(for: handle)
            if let current = layout.item(matching: item) {
                completion([UIAction(title: "名前を変える", image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.presentTabRename(current)
                }, UIAction(title: "タブから外す", image: UIImage(systemName: "rectangle.stack.badge.minus"), attributes: .destructive) { [weak self] _ in
                    self?.setTabLayout(AppDependencies.settings.tabLayout(for: handle).removing(item))
                    self?.showTabLayoutNotice("タブから外しました")
                }])
            } else {
                completion([UIAction(title: "タブに追加", subtitle: "切り替えタブに入ります", image: UIImage(systemName: "rectangle.stack.badge.plus")) { [weak self] _ in
                    self?.setTabLayout(AppDependencies.settings.tabLayout(for: handle).adding(item))
                    self?.showTabLayoutNotice("タブに追加しました")
                }])
            }
        }])
        // 右上に入り切らず「さらに表示」にまとめられたときも、何のボタンか分かるよう名前を付ける。
        return UIBarButtonItem(title: "タブ", image: UIImage(systemName: "rectangle.stack"), menu: menu)
    }

    /// ユーザーのハッシュタグとプロフィールのタブの名前を変える。空にすると、既定の名前（`#名前`や`@name`）に戻す。
    private func presentTabRename(_ item: TabItem) {
        guard item.isUserAdded else { return }
        let handle = credential.handle
        let defaultTitle = item.renamed("").title
        let alert = UIAlertController(title: "タブの名前", message: "空にすると「\(defaultTitle)」に戻ります", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = item.title == defaultTitle ? "" : item.title
            field.placeholder = defaultTitle
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            let renamed = item.renamed(text.trimmingCharacters(in: .whitespacesAndNewlines))
            self?.setTabLayout(AppDependencies.settings.tabLayout(for: handle).replacing(renamed))
        })
        topViewController.present(alert, animated: true)
    }

    private func showTabLayoutNotice(_ title: String) {
        notices.showTransient(Notice(id: "tabs.layoutChanged", kind: .success, title: title), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    /// 一覧を開いた画面に積み、すぐ読み始めてストリームを購読する。ナビゲーションから外されたら止める。
    private func openFeed(_ feed: TimelineFeed, texts: TimelineViewController.Texts? = nil, barItems: [UIBarButtonItem] = [], from source: UIViewController) {
        guard let navigation = source.navigationController else { return }
        let controller = FeedTimelineController(feed: feed, texts: texts, session: session)
        let viewController = controller.viewController
        configure(viewController)
        viewController.screenBarItems = barItems
        // 画面が積まれている間だけ生かす。コントローラーは画面を強く持つので互いに持ち合うが、外されたときと、ログアウトなどで止めるときに、`stop()`が持ち合いを解く。
        viewController.lifetimeOwner = controller
        viewController.onRemovedFromParent = { [weak controller] in controller?.stop() }
        controller.showStreamingState(streamingHub.state)
        pushedFeeds.add(controller)
        navigation.pushViewController(viewController, animated: true)
        controller.start(purpose: .action)
    }

    /// `url`を`browser`で開く。アプリ内のSafariはhttpとhttps以外のURLで例外を出して落ちるため、呼ぶ側が`LinkBrowser.browser(for:)`などで確かめてから渡す。
    private func open(_ url: URL, in browser: LinkBrowser) {
        switch browser {
        case .external: UIApplication.shared.open(url)
        case .inApp: self.browser.open(url, from: rootViewController)
        }
    }

    private func openProfile(accountID: String, from source: UIViewController) {
        let client = client
        openProfile(from: source) { try await client.account(accountID) }
    }

    /// プロフィールのURLでアカウントを探して開く。自分のサーバーが知らないアカウントも、相手のサーバーに問い合わせて探す。
    private func openProfile(resolving url: URL, acct: String, from source: UIViewController) {
        let client = client
        let accounts = accounts
        let logger = logger
        openProfile(from: source) {
            guard let account = try await accounts.resolve(.profileURL(url), search: { try await client.resolveAccount(at: url) }) else {
                logger.error("profile not found host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash))")
                throw ProfileNotFound(acct: acct)
            }
            return account
        }
    }

    /// リンクのメニューの「プロフィールとして開く」。リンク先をプロフィールとして探し、見つかれば開く。探すにはサーバーが相手のページを取りに行くため、時間がかかりやすい。
    private func openProfile(resolvingLink url: URL, from source: UIViewController) {
        let client = client
        let accounts = accounts
        let logger = logger
        openProfile(from: source) {
            guard let account = try await accounts.resolve(.profileURL(url), search: { try await client.resolveAccount(at: url) }) else {
                logger.info("profile not found for link host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash))")
                throw LinkProfileNotFound()
            }
            return account
        }
    }

    /// プロフィールを開く操作は、どの経路もここに通す。`find`で探したアカウントのプロフィールを、`source`の画面に積む。
    /// 探している途中に別のプロフィールを開こうとしたら、前のものは止めて結果を使わない。待っている間も、ほかの操作は止めない。
    /// 待つ間にタブを移ったり、戻ったり、別の画面を開いたりしたら、見つかっても積まず、失敗も知らせない。
    private func openProfile(from source: UIViewController, failureTitle: String = "プロフィールを開けませんでした", finding find: @escaping @Sendable () async throws -> Account) {
        let anchor = PushAnchor(source)
        profileOpening.start(.action, debugDelayed(find)) { [logger] in
            guard anchor.isStillShowing else {
                logger.info("profile open dropped: screen changed while finding")
                return false
            }
            return true
        } completion: { [weak self, weak source] result in
            guard let self, let source else { return }
            switch result {
            case .success(let account):
                pushProfile(account, from: source)
            case .failure(let error):
                handle(error, title: failureTitle)
            }
        }
    }

    /// デバッグ版で`scia-debug://lookup/slow`にしていれば、相手を探す前に待つ。待つ間に止められたら、探さない。
    private func debugDelayed<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) -> @Sendable () async throws -> Value {
        #if DEBUG
        let clock = clock
        return {
            if let delay = DebugFaults.slowLookupDelay {
                try await clock.sleep(for: delay)
            }
            return try await work()
        }
        #else
        return work
        #endif
    }

    private static let profileLookupActivityID = "profile.lookup"

    /// プロフィールを探すのが長引いている間、「取得中」のチップと「操作の状況」の行を出す。
    private func showProfileLookupProgress(_ isSlow: Bool) {
        guard isSlow else {
            operationStatus.end(Self.profileLookupActivityID)
            notices.setPersistent(nil, in: .profileLookup)
            return
        }
        // 「操作の状況」の行から止めたら、見つかってもプロフィールを開かない。
        operationStatus.update(OperationStatus.Activity(id: Self.profileLookupActivityID, title: Notice.profileLookup.title)) { [weak self] in
            self?.profileOpening.cancel()
        }
        notices.setPersistent({ _ in .profileLookup }, in: .profileLookup)
    }

    // MARK: - プロフィール

    /// アイコンや通知の送った人のように、探さずに開けるプロフィールを開く。後から押したものを勝たせるため、探している途中のプロフィールは止める。
    private func openProfile(_ account: Account, from source: UIViewController) {
        profileOpening.cancel()
        pushProfile(account, from: source)
    }

    private func pushProfile(_ account: Account, from source: UIViewController) {
        let (controller, viewController) = makeProfile(account, tasks: tasks.child())
        viewController.screenBarItems.append(tabToggleItem(for: .profile(accountID: account.id, acct: account.acct)))
        UserAction.openProfile.record()
        source.navigationController?.pushViewController(viewController, animated: true)
        controller.start()
    }

    /// プロフィール画面を作り、投稿への操作とリンクを開けるようにする。積んで開くものとタブに置くもので使う。
    private func makeProfile(_ account: Account, tasks: TaskScope) -> (ProfileController, TimelineViewController) {
        let (controller, viewController) = ProfileController.make(account: account, client: client, relationshipCache: profiles.relationships, tasks: tasks) { [weak self] error, title in
            self?.handle(error, title: title)
        } onUnauthorized: { [weak self] in
            self?.reportUnauthorized()
        }
        configure(viewController)
        controller.onEditProfile = { [weak self] in self?.presentProfileEditor() }
        controller.onEndorsementRemoved = { [weak self] in
            guard let self else { return }
            profiles.reloadFeatured(of: credential.accountID)
        }
        controller.onOpenAccountList = { [weak self, weak viewController] kind in
            guard let viewController else { return }
            self?.openAccountList(kind, ownerAcct: account.acct, from: viewController)
        }
        controller.onOpenLink = { [weak self, weak viewController] destination in
            guard let viewController else { return }
            self?.open(destination, inProfileFrom: viewController)
        }
        profiles.add(controller)
        return (controller, viewController)
    }

    // MARK: - 人の一覧

    /// まとめた通知を送った人の一覧を開く。お気に入りとブーストは対象の投稿の、フォローは自分のフォロワーの全員の一覧にする。
    /// まとまりに入った人だけの一覧ではない。Mastodonのwebと同じ。
    private func openAccountList(of notification: MastodonNotification, from source: UIViewController) {
        let kind: AccountListKind? = switch notification.type {
        case .favourite: notification.status.map { .favouritedBy($0.id) }
        case .reblog: notification.status.map { .rebloggedBy($0.id) }
        case .follow: .followers(accountID: credential.accountID)
        default: nil
        }
        guard let kind else { return }
        openAccountList(kind, ownerAcct: notification.type == .follow ? credential.username : nil, from: source)
    }

    /// - Parameter ownerAcct: フォローとフォロワーの一覧なら、誰の一覧かを示すハンドル。見出しの下に出す。
    private func openAccountList(_ kind: AccountListKind, ownerAcct: String? = nil, from source: UIViewController) {
        let (controller, viewController) = AccountListController.make(kind: kind, client: client, tasks: tasks.child()) { [weak self] in
            self?.reportUnauthorized()
        }
        viewController.navigationItem.subtitle = ownerAcct.map { "@\($0)" }
        UserAction.openAccountList.record()
        configure(viewController)
        source.navigationController?.pushViewController(viewController, animated: true)
        controller.start(purpose: .action)
    }

    // MARK: - 保留中の通知

    /// 通知のタブの右上に保留中の通知を開くボタンを置き、人数を添える。決まりはdocs/notification-filter.mdの「入口」にある。
    private func installNotificationRequests() {
        let item = UIBarButtonItem(image: UIImage(systemName: "tray"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            openNotificationRequests(from: notifications.viewController)
        })
        notifications.viewController.screenBarItems = [item]
        notifications.onReload = { [weak notificationPolicy] in notificationPolicy?.reload(purpose: .display) }
        notificationPolicy.onFailure = { [weak self] reason in
            guard let self else { return }
            let title = "通知のフィルタリングを変えられませんでした"
            operationStatus.recordFailure(title: title, reason: reason)
            showFailureNotice(.interactionFailure(title: title) { [weak self] in
                self?.presentAlert(title: title, message: reason.text)
            })
        }
        observePendingRequests(item)
    }

    /// 人数が変わるたびに、ボタンの数字と読み上げを直す。サーバーは100で止めるので、100なら「100+」にする。
    private func observePendingRequests(_ item: UIBarButtonItem) {
        withObservationTracking {
            let count = notificationPolicy.pendingRequestsCount
            let text = count >= NotificationPolicyModel.pendingRequestsCap ? "\(count)+" : "\(count)"
            item.badge = count == 0 ? nil : .string(text)
            item.accessibilityLabel = count == 0 ? "保留中の通知" : "保留中の通知、\(text)人"
        } onChange: { [weak self, weak item] in
            Task(.withoutRequests) { @MainActor [weak self, weak item] in
                guard let self, let item, !tasks.isClosed else { return }
                observePendingRequests(item)
            }
        }
    }

    /// 通知のタブを選んで、保留中の通知の一覧を開く。通知のタブを並べていなければ何もしない。
    @discardableResult
    private func openNotificationRequestsInTab() -> (NotificationRequestsController, TimelineViewController)? {
        guard tabs.placement.location(of: .notifications) != .disabled else { return nil }
        tabs.show(.notifications)
        return openNotificationRequests(from: notifications.viewController)
    }

    /// 保留中の通知の一覧を開く。
    @discardableResult
    private func openNotificationRequests(from source: UIViewController) -> (NotificationRequestsController, TimelineViewController) {
        let (controller, viewController) = NotificationRequestsController.make(client: client, tasks: tasks.child(), openPolicy: { [weak self] in
            self?.showNotificationPolicy()
        }) { [weak self] in
            self?.reportUnauthorized()
        }
        controller.model.onAnswered = { [weak self] decision in
            guard let self else { return }
            notificationPolicy.requestsDidChange()
            if decision == .accept {
                notifications.didAcceptRequest()
            }
        }
        controller.model.onFailure = { [weak self] decision, reason in
            guard let self else { return }
            let title = switch decision {
            case .accept: "通知を受け入れられませんでした"
            case .dismiss: "通知を無視できませんでした"
            }
            operationStatus.recordFailure(title: title, reason: reason)
            showFailureNotice(.interactionFailure(title: title) { [weak self] in
                self?.presentAlert(title: title, message: reason.text)
            })
        }
        viewController.onOpenNotificationRequest = { [weak self, weak controller, weak viewController] request in
            guard let self, let controller, let viewController else { return }
            openAccountNotifications(of: request, in: controller.model, from: viewController)
        }
        configure(viewController)
        source.navigationController?.pushViewController(viewController, animated: true)
        controller.model.start(purpose: .action)
        return (controller, viewController)
    }

    /// 保留中の通知の1人分の、その人からの通知を開く。受け入れるか無視が済んだら、一覧の画面に戻る。
    private func openAccountNotifications(of request: NotificationRequest, in requests: NotificationRequestsModel, from source: UIViewController) {
        let (controller, viewController) = AccountNotificationsController.make(request: request, client: client, tasks: tasks.child(), answer: { [weak requests] decision in
            guard let requests else { return false }
            await requests.answer(request, decision)?.value
            return requests.isAnswered(request.id)
        }) { [weak self] in
            self?.reportUnauthorized()
        }
        notifications.track(controller)
        configure(viewController)
        source.navigationController?.pushViewController(viewController, animated: true)
        controller.model.start(purpose: .action)
    }

    /// サーバーのお知らせの一覧をシートで開く。リンクを押したら、シートを閉じてから、選んでいるタブの画面に開く。「操作の状況」と同じ。
    func showAnnouncements(from presenter: UIViewController? = nil) {
        // シートは1つのモデルを画面として受け持つので、開いているときに重ねて開かない。重ねると、閉じて戻ったシートに変化が届かなくなる。
        if let presentedAnnouncements, presentedAnnouncements.presentingViewController != nil, !presentedAnnouncements.isBeingDismissed { return }
        let completion = TextInputCompletion(
            completion: ComposeCompletion(sources: completionSources, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning), emojis: customEmojis.emojis),
            recentEmojis: RecentEmojis(defaults: .standard, instance: credential.instance)
        )
        let controller = AnnouncementsViewController(model: announcements, completion: completion)
        controller.notices = notices
        controller.userMenuActions = userMenuActions
        controller.hashtagMenuActions = hashtagMenuActions
        controller.onOpenLink = { [weak self, weak controller] destination, announcement in
            controller?.dismiss(animated: true) {
                self?.open(destination, inAnnouncement: announcement)
            }
        }
        controller.onOpenURL = { [weak self, weak controller] url, browser in
            controller?.dismiss(animated: true) {
                self?.open(url, in: browser)
            }
        }
        controller.onOpenProfileURL = { [weak self, weak controller] url in
            controller?.dismiss(animated: true) { [weak self] in
                guard let self, let source = tabs.selectedNavigation?.topViewController else { return }
                openProfile(resolvingLink: url, from: source)
            }
        }
        let navigation = AnnouncementsNavigationController(rootViewController: controller)
        presentedAnnouncements = navigation
        (presenter ?? topViewController).present(navigation, animated: true)
    }

    /// お知らせの本文のリンクを開く。メンションはお知らせのメンションの一覧にあるIDで、投稿へのリンクはお知らせがリンクした投稿のIDで開く。
    private func open(_ destination: RichText.LinkDestination, inAnnouncement announcement: Announcement) {
        guard let source = tabs.selectedNavigation?.topViewController else { return }
        switch destination {
        case .url(let url):
            if let linked = announcement.statuses.first(where: { $0.url == url }) {
                openThread(statusID: linked.id, rowFrame: .zero, from: source)
            } else {
                open(url, in: AppDependencies.settings.linkBrowser.browser(for: url))
            }
        case .mention(let acct, let url):
            if let mention = announcement.mentions.first(where: { $0.url == url || $0.acct == acct }) {
                openProfile(accountID: mention.id, from: source)
            } else {
                openProfile(resolving: url, acct: acct, from: source)
            }
        case .hashtag(let name, _):
            openFeed(.hashtag(name: name), from: source)
        }
    }

    /// お知らせのリアクションの失敗。投稿への操作と同じく、数秒で消えるチップで知らせ、押すと理由を出す。
    private func reportAnnouncementReactionFailure(_ error: any Error) {
        let title = "リアクションを変更できませんでした"
        // 401なら、トークンが無効かを確かめてから理由を決めるので、通信することがある。
        tasks.run(.action) { [weak self] in
            guard let self else { return }
            let reason = await failureReason(for: error)
            operationStatus.recordFailure(title: title, reason: reason)
            showFailureNotice(.interactionFailure(title: title) { [weak self] in
                self?.presentAlert(title: title, message: reason.text)
            })
        }
    }

    /// 通知のフィルタリングの設定をシートで開く。
    func showNotificationPolicy(from presenter: UIViewController? = nil) {
        (presenter ?? topViewController).present(NotificationPolicyView.makeSheet(model: notificationPolicy), animated: true)
    }

    // MARK: - 検索

    /// 検索の画面に、候補と結果を並べる一覧と、確定した語の結果を読むモデルを作らせる。
    private func prepare(_ search: SearchViewController) {
        search.makeResults = { [weak self] input, carried, list in
            self?.makeSearchModel(input, scope: .all, carried: carried, presenter: list)
        }
        search.makeList = { [weak self, weak search] in
            let list = TimelineViewController(texts: .search(.all, query: "")) { await search?.refreshResults() }
            self?.configure(list)
            return list
        }
        search.onOpenHashtag = { [weak self] name, source in self?.openFeed(.hashtag(name: name), from: source) }
        search.onResultRowSelect = { [weak self] row, model, source in self?.selectSearchResultRow(row, of: model, from: source) }
        search.suggestions = SearchSuggestions(
            client: client,
            recents: RecentSearches(defaults: .standard, account: credential.handle),
            settings: TuningCatalog.completionSettings(in: AppDependencies.tuning),
            tasks: tasks.child()
        )
    }

    /// 検索のタブを開く。語があれば確定する。検索を無効にしていれば、選んでいるタブに検索の画面を積んで開く。
    private func showSearch(query: String?) {
        if tabs.placement.location(of: .search) != .disabled {
            tabs.show(.search)
            if let query {
                searchRoot.navigationController?.popToRootViewController(animated: false)
                searchRoot.submit(query)
            }
            return
        }
        guard let navigation = tabs.selectedNavigation else { return }
        let search = SearchViewController()
        prepare(search)
        if let query {
            search.submit(query)
        }
        navigation.pushViewController(search, animated: true)
    }

    /// 確定した語の結果の一覧を作り、探し始める。「すべて見る」で積む、1つの種類だけの一覧に使う。決まりはdocs/search.mdにある。
    private func makeSearchResults(_ input: SearchInput, scope: SearchModel.Scope) -> TimelineViewController {
        weak var owner: SearchModel?
        let viewController = TimelineViewController(texts: .search(scope, query: input.query)) { await owner?.refresh() }
        let model = makeSearchModel(input, scope: scope, carried: nil, presenter: viewController)
        owner = model
        model.display = viewController
        viewController.lifetimeOwner = model
        // 画面を外したら、読み込みをやめる。走っている読み込みがモデルを持ち続け、通信が終わるまで残るため。
        // 別の語を確定して結果を差し替えたときと、「すべて見る」の一覧から戻ったときに外れる。
        viewController.onRemovedFromParent = { [weak model] in model?.stop() }
        viewController.onApproachingEnd = { [weak model] in model?.approachEnd() }
        viewController.onRetry = { [weak model] in model?.retry() }
        viewController.onSearchRowSelect = { [weak self, weak viewController, weak model] row in
            guard let self, let viewController else { return }
            selectSearchResultRow(row, of: model, from: viewController)
        }
        configure(viewController)
        model.start()
        return viewController
    }

    /// 検索の結果のハッシュタグ、「すべて見る」、失敗の行を押したときの扱い。検索の画面と「すべて見る」で積む一覧で共有する。
    /// - Parameter model: 行を並べた結果。打っている途中の候補のハッシュタグを押したときはnil。
    private func selectSearchResultRow(_ row: SearchRow, of model: SearchModel?, from source: UIViewController) {
        switch row {
        case .hashtag(let hashtag):
            openFeed(.hashtag(name: hashtag.name), from: source)
        case .showAll(let category):
            guard let model else { return }
            source.navigationController?.pushViewController(makeSearchResults(model.input, scope: .only(category)), animated: true)
        case .failed(let category, _):
            model?.retry(category)
        case .heading, .action, .recentsHeading, .recent:
            // 打っている途中の候補にだけ出る行は、検索の画面が扱う。
            break
        }
    }

    /// 確定した語の結果を読むモデルを作る。結果を伝える一覧と読み始めは、呼び出し側が決める。
    /// - Parameters:
    ///   - carried: 打っている途中の候補。そのユーザーとハッシュタグを、結果が届くまで引き継ぐ。
    ///   - presenter: 結果を並べる一覧。URLやハンドルが1つに決まったときに、この上に開く。
    private func makeSearchModel(_ input: SearchInput, scope: SearchModel.Scope, carried: SearchSuggestions.Content?, presenter viewController: TimelineViewController) -> SearchModel {
        let model = SearchModel(input: input, scope: scope, carriedAccounts: carried?.accounts ?? [], carriedHashtags: carried?.hashtags ?? [], client: client, tasks: tasks.child()) { [weak self] in
            self?.reportUnauthorized()
        }
        // URLやハンドルが1つに決まったら、結果の一覧の上に開く。待つ間にタブを移ったり、ほかの画面を開いたりしていたら開かない。
        model.onFound = { [weak self, weak viewController] found in
            // 添付ファイルのビューアのように元の画面をウインドウに残したまま重ねる画面は、ナビゲーションの外にあるため、重ねている画面で見る。検索欄（`UISearchController`）は除く。
            guard let self, let viewController, viewController.view.window != nil,
                  viewController.navigationController?.topViewController === (viewController.parent ?? viewController) else { return }
            let presented = viewController.navigationController?.presentedViewController
            guard presented == nil || presented is UISearchController else { return }
            // 検索欄で打ち直している間は、前の語で決まっても開かない。欄の語と違うものが開くため。
            if let search = viewController.parent as? SearchViewController, !search.isShowingResults { return }
            switch found {
            case .status(let status):
                // 押した行がないため、一覧の安全領域の上端に置いて開く。
                openThread(of: status, rowFrame: viewController.view.convert(viewController.view.safeAreaLayoutGuide.layoutFrame, to: nil), from: viewController)
            case .account(let account):
                openProfile(account, from: viewController)
            }
        }
        searches.add(model)
        return model
    }

    // MARK: - スレッド

    /// 押した投稿のスレッドを開く。ブーストを押したときは、ブーストされた投稿のスレッドにする。
    /// - Parameter rowFrame: 押した行のウインドウ上の枠。スレッドでも、押した投稿をこの位置に置いて開く。
    private func openThread(of status: Status, rowFrame: CGRect, from source: UIViewController) {
        let focus = status.displayed
        let (controller, viewController) = ThreadController.make(focus: focus, client: client, streamingHub: streamingHub, tasks: tasks.child()) { [weak self] in
            self?.reportUnauthorized()
        }
        configure(viewController)
        threads.add(controller)
        controller.start()
        viewController.placeOnAppearing(.status(focus.id), atWindowY: rowFrame.minY)
        guard let navigation = source.navigationController else { return }
        ThreadPushDelegate.push(viewController, on: navigation, duration: viewController.tuning.value(of: TuningCatalog.threadOpenDuration))
    }

    /// IDしか分からない投稿を読んでから、そのスレッドを開く。待つ間にタブを移ったり、戻ったり、別の画面を開いたりしたら、読めても開かず、失敗も知らせない。
    private func openThread(statusID: Status.ID, rowFrame: CGRect, from source: UIViewController) {
        let client = client
        let anchor = PushAnchor(source)
        statusOpening.start(.action, { try await client.status(statusID) }) { anchor.isStillShowing } completion: { [weak self, weak source] result in
            guard let self, let source else { return }
            switch result {
            case .success(let status):
                openThread(of: status, rowFrame: rowFrame, from: source)
            case .failure(let error):
                handle(error, title: "投稿を開けませんでした")
            }
        }
    }

    /// 自分のプロフィールの編集をシートで開く。保存したら、開いている自分のプロフィールに反映する。
    /// - Parameters:
    ///   - debugNote: デバッグURLで渡した、読み込んだあとに置き換える自己紹介。
    ///   - debugField: デバッグURLで渡した、読み込んだあとに足す補足情報の内容。
    ///   - debugCrop: デバッグURLで渡した、読み込んだあとにダミーの画像で切り抜きを開く画像。
    private func presentProfileEditor(debugNote: String? = nil, debugField: String? = nil, debugCrop: ProfileImage? = nil) {
        let editor = ProfileEditor(api: ProfileEditor.API(client: client))
        // 注目のハッシュタグか紹介しているユーザーを送れたら、途中で送れなくなっても、覚えている自分のタグと開いている自分のプロフィールの棚を読み直す。
        editor.onFeaturedChange = { [weak self] in self?.ownFeaturedTagsDidChange() }
        // そのあとに注目のハッシュタグや紹介を送れずにシートを閉じなくても、保存できたプロフィールは開いている自分のプロフィールに反映する。
        editor.onProfileSaved = { [weak self] saved in
            self?.cachedMyAccount = saved.account
            self?.profiles.apply(edited: saved.account)
        }
        // 上限を読めなければ、4.6.0より前のMastodonの値のまま使う。超えた分はサーバーが拒む。
        tasks.run(.action) { [weak self] in
            guard let configuration = await self?.session.loadInstanceConfiguration() else { return }
            editor.limits = configuration.profileLimits
            editor.charactersReservedPerURL = configuration.charactersReservedPerURL
        }
        let completion = TextInputCompletion(
            completion: ComposeCompletion(sources: completionSources, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning), recentMentions: RecentMentions(defaults: .standard, account: credential.handle), emojis: customEmojis.emojis),
            recentEmojis: RecentEmojis(defaults: .standard, instance: credential.instance)
        )
        // 紹介しているユーザーの追加の行は、サーバーがフォローしていない相手を断るので、フォローしている人だけから探す。
        var endorsementSources = ComposeCompletion.Sources.unavailable
        endorsementSources.searchAccounts = { [client] query, limit in try await client.searchAccountsForCompletion(query, limit: limit, following: true) }
        let endorsementCompletion = TextInputCompletion(
            completion: ComposeCompletion(sources: endorsementSources, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning)),
            recentEmojis: nil
        )
        let controller = ProfileEditViewController(editor: editor, completion: completion, endorsementCompletion: endorsementCompletion)
        controller.onError = { [weak self] error, title in self?.handle(error, title: title) }
        #if DEBUG
        controller.debugNote = debugNote
        controller.debugField = debugField
        controller.debugCrop = debugCrop
        #endif
        rootViewController.frontmostPresented.present(controller.wrappedInNavigation(), animated: true)
    }

    /// ログイン中のアカウント。手元にはCredentialしかないため、一度読んだら使い回す。
    func myAccount() async throws -> Account {
        if let cachedMyAccount { return cachedMyAccount }
        let account = try await client.account(client.credential.accountID)
        // 読む間にプロフィールを保存していれば、保存した方が新しいので、読み始めた時点の応答で戻さない。
        if let cachedMyAccount { return cachedMyAccount }
        cachedMyAccount = account
        return account
    }

    private func openMyProfile(from source: UIViewController) {
        let logger = logger
        openProfile(from: source, failureTitle: "プロフィールを読み込めませんでした") { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                return try await myAccount()
            } catch {
                logger.error("my profile load failed: \(SciaLog.describe(error), privacy: .public)")
                throw error
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
        if let timeline = TimelineViewController.shown(in: tabs.selectedNavigation?.topViewController),
           timeline.scrollToStatus(subject.statusID, displayedID: subject.displayedID, at: .centeredVertically) {
            return
        }
        if let url = subject.url {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 投稿への操作

    /// - Parameter timeline: 操作した一覧。編集履歴は、この一覧の上に重ねて開く。
    private func perform(_ action: StatusAction, on status: Status, from timeline: TimelineViewController?) {
        switch action {
        case .reply:
            UserAction.reply.record()
            confirmLeavingEdit(starting: "返信") { [weak self] in self?.composer.reply(to: status) }
        case .quote:
            UserAction.quote.record()
            startQuoting(status)
        case .favourite:
            UserAction.toggleFavourite.record()
            toggle(.favourite, on: status, failureTitle: "お気に入りを変更できませんでした")
        case .reblog:
            UserAction.toggleReblog.record()
            toggle(.reblog, on: status, reblogVisibility: AppDependencies.settings.reblogVisibility, failureTitle: "ブーストを変更できませんでした")
        case .reblogWithVisibility(let visibility):
            UserAction.toggleReblog.record()
            toggle(.reblog, on: status, reblogVisibility: visibility, failureTitle: "ブーストできませんでした")
        case .bookmark:
            UserAction.toggleBookmark.record()
            let done = status.displayed.bookmarked ? "ブックマークを外しました" : "ブックマークしました"
            toggle(.bookmark, on: status, failureTitle: "ブックマークを変更できませんでした") { [weak self] in
                self?.showToggledNotice(done)
            }
        case .muteConversation:
            UserAction.toggleConversationMute.record()
            let done = status.displayed.muted ? "会話のミュートを解除しました" : "会話をミュートしました"
            toggle(.muteConversation, on: status, failureTitle: "会話のミュートを変更できませんでした") { [weak self] in
                self?.showToggledNotice(done)
            }
        case .pin:
            UserAction.togglePin.record()
            let done = status.displayed.pinned ? "プロフィールの固定を外しました" : "プロフィールに固定しました"
            // 固定の数の上限を超えたときは、サーバーの422の文言が理由に出る。
            toggle(.pin, on: status, failureTitle: "プロフィールの固定を変更できませんでした") { [weak self] in
                guard let self else { return }
                profiles.reloadPinned(of: credential.accountID)
                showToggledNotice(done)
            }
        case .editHistory:
            UserAction.openEditHistory.record()
            // フィルターの結果はブーストの外側にだけ付くことがあるため、判定にはブーストごと渡す。
            let filterTitles = timeline?.filterWarnings.verdict(for: status).mediaTitles ?? []
            openEditHistory(of: status.displayed, filterTitles: filterTitles, from: timeline)
        case .openFavouritedBy:
            guard let timeline else { return }
            openAccountList(.favouritedBy(status.displayed.id), from: timeline)
        case .openRebloggedBy:
            guard let timeline else { return }
            openAccountList(.rebloggedBy(status.displayed.id), from: timeline)
        case .edit:
            UserAction.editStatus.record()
            startEditing(status)
        case .delete:
            confirmDeleting(status)
        case .redraft:
            UserAction.redraftStatus.record()
            startRedrafting(status)
        case .viewAPIResponse:
            // ブーストなら、ブーストの応答に元の投稿が入っているので、ブーストのIDで読む。
            openAPIResponse(statusID: status.id, from: timeline)
        }
    }

    /// 投稿をサーバーから読み直したAPIの応答を、操作した画面に積んで開く。
    private func openAPIResponse(statusID: Status.ID, from source: UIViewController?) {
        let client = client
        let viewController = APIResponseViewController {
            try await client.statusResponse(statusID)
        } describe: { [weak self] error in
            await self?.failureReason(for: error) ?? ErrorPresentation(error)
        }
        viewController.notices = notices
        source?.navigationController?.pushViewController(viewController, animated: true)
    }

    /// 編集履歴を、操作した一覧の上に重ねて開く。履歴は開いた画面が読む。
    /// - Parameter filterTitles: 添付ファイルをぼかすフィルターのうち、操作した一覧で一致したものの名前。
    private func openEditHistory(of status: Status, filterTitles: [String], from source: UIViewController?) {
        let client = client
        // トークンが無効なら、理由はチップの列の一番上のログインし直しの段へ案内する。ログインし直したあとは、再試行で読める。
        let viewController = EditHistoryViewController(status: status) {
            try await client.statusHistory(status.id)
        } describe: { [weak self] error in
            await self?.failureReason(for: error) ?? ErrorPresentation(error)
        }
        editHistories.add(viewController)
        viewController.mediaCovers = mediaCovers
        viewController.filterTitles = filterTitles
        viewController.onChangeMediaCovers = { [weak self, weak viewController] covers, status in
            self?.shareMediaCovers(covers, changed: status, from: viewController)
        }
        viewController.notices = notices
        viewController.mediaTransfers = mediaTransfers
        viewController.onOpenURL = { [weak self] url, browser in self?.open(url, in: browser) }
        viewController.onOpenProfileURL = { [weak self, weak viewController] url in
            guard let viewController else { return }
            self?.openProfile(resolvingLink: url, from: viewController)
        }
        viewController.onOpenAccountHashtag = { [weak self, weak viewController] name, account in
            guard let viewController else { return }
            self?.openAccountHashtag(name, of: account, from: viewController)
        }
        viewController.userMenuActions = userMenuActions
        viewController.hashtagMenuActions = hashtagMenuActions
        viewController.onOpenLink = { [weak self, weak viewController] destination in
            guard let self, let viewController else { return }
            // 編集で消したメンションは、今の投稿のメンションの一覧にないため、一覧と同じ引き方ではIDが分からない。プロフィールのURLから探す。
            if case .mention(let acct, let url) = destination, !status.mentions.contains(where: { $0.url == url || $0.acct == acct }) {
                openProfile(resolving: url, acct: acct, from: viewController)
            } else {
                open(destination, in: status, from: viewController)
            }
        }
        source?.navigationController?.pushViewController(viewController, animated: true)
    }

    /// ハッシュタグのメニューの、自分の状態を読んで変える項目。
    private var hashtagMenuActions: HashtagMenuActions {
        HashtagMenuActions(mute: hashtagMuteActions, feature: hashtagFeatureActions)
    }

    /// ハッシュタグのメニューの「プロフィールで紹介する」。覚えている自分の注目のハッシュタグで載せているかを決め、メニューを開くたびに読み直す。
    private var hashtagFeatureActions: HashtagFeatureActions {
        let ownFeaturedTags = ownFeaturedTags
        return HashtagFeatureActions(
            known: { name in ownFeaturedTags.value.map { $0.first(named: name) != nil } },
            // まだ読めていなければ、開いたメニューがこの読み直しを待つので、操作として送る。
            refresh: { ownFeaturedTags.refresh(purpose: .action) },
            load: { name in try await ownFeaturedTags.latest().first(named: name) != nil },
            feature: { [weak self] name in self?.featureHashtag(name) },
            unfeature: { [weak self] name in self?.unfeatureHashtag(name) }
        )
    }

    /// ハッシュタグを自分のプロフィールの注目のハッシュタグに載せる。上限を超えたときなどは、サーバーが返す理由を知らせる。
    private func featureHashtag(_ name: String) {
        let client = client
        logger.info("hashtag feature")
        // 送り終える前にメニューを開き直して押しても、同じ要求を重ねて送らない。二重に載せようとすると、サーバーが断るため。
        tasks.run(key: "hashtagFeature:\(name)", .skippingWhileRunning, .action) { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.featureTag(name)
                ownFeaturedTagsDidChange()
                notices.showTransient(Notice(id: "hashtag.featureChanged", kind: .success, title: "#\(name)をプロフィールで紹介しました"), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
            } catch {
                logger.error("hashtag feature failed: \(SciaLog.describe(error), privacy: .public)")
                // 応答が届かなかっただけで載っていることがあるので、読み直す。
                ownFeaturedTags.reload(purpose: .action)
                handle(error, title: "プロフィールでの紹介を変更できませんでした")
            }
        }
    }

    /// ハッシュタグを自分のプロフィールの注目のハッシュタグから外す。外すIDは、外すときに読み直した一覧で決める。
    /// 別の端末やwebで消したり足し直したりしたタグを、メニューを組んだときに覚えていた古いIDで消さないため。もう載っていなければ、外れているとして知らせる。
    private func unfeatureHashtag(_ name: String) {
        let client = client
        logger.info("hashtag unfeature")
        tasks.run(key: "hashtagFeature:\(name)", .skippingWhileRunning, .action) { [weak self] in
            guard let self else { return }
            do {
                ownFeaturedTags.reload(purpose: .action)
                if let featured = try await ownFeaturedTags.latest().first(named: name) {
                    try await client.unfeatureTag(featured.id)
                }
                ownFeaturedTagsDidChange()
                notices.showTransient(Notice(id: "hashtag.featureChanged", kind: .success, title: "#\(name)をプロフィールから外しました"), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
            } catch {
                logger.error("hashtag unfeature failed: \(SciaLog.describe(error), privacy: .public)")
                ownFeaturedTags.reload(purpose: .action)
                handle(error, title: "プロフィールでの紹介を変更できませんでした")
            }
        }
    }

    /// 自分の注目のハッシュタグを変えたあとに、覚えている一覧、投稿欄の補完の自分のタグ、開いている自分のプロフィールの棚を読み直す。
    private func ownFeaturedTagsDidChange() {
        ownFeaturedTags.reload(purpose: .action)
        composer.completion.forgetOwnTags()
        profiles.reloadFeatured(of: credential.accountID)
    }

    /// ハッシュタグのメニューのミュート。覚えている自分のフィルターでミュートしているかを決め、メニューを開くたびに読み直す。
    private var hashtagMuteActions: HashtagMuteActions {
        let serverFilters = serverFilters
        let now = now
        return HashtagMuteActions(
            known: { name in serverFilters.value.map { HashtagMute.find(name, in: $0, now: now()) != nil } },
            // まだ読めていなければ、開いたメニューがこの読み直しを待つので、操作として送る。
            refresh: { serverFilters.refresh(purpose: .action) },
            load: { name in HashtagMute.find(name, in: try await serverFilters.latest(), now: now()) != nil },
            mute: { [weak self] name, duration in self?.muteHashtag(name, duration: duration) },
            unmute: { [weak self] name in self?.unmuteHashtag(name) }
        )
    }

    /// ハッシュタグをミュートするフィルターを作り、タイムラインと通知から、そのタグの付いた投稿を閉じる動きで除いて、あとから届いても足さない。
    /// 開いているプロフィールとスレッドからは除かない。期限を付けたら、期限が来たときにまた足す。
    private func muteHashtag(_ name: String, duration: Duration?) {
        let client = client
        logger.info("hashtag mute")
        // 送り終える前にメニューを開き直して押しても、同じ要求を重ねて送らない。
        tasks.run(key: "hashtagMute:\(name)", .skippingWhileRunning, .action) { [weak self] in
            guard let self else { return }
            do {
                try await HashtagMute.mute(name, duration: duration, client: client)
                serverFilters.reload(purpose: .action)
                excludeInLists(tag: name, excluded: true)
                if let duration {
                    includeAfterHashtagMuteExpires(name, duration: duration)
                }
                notices.showTransient(Notice(id: "hashtag.muteChanged", kind: .success, title: "#\(name)をミュートしました"), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
            } catch {
                logger.error("hashtag mute failed: \(SciaLog.describe(error), privacy: .public)")
                handle(error, title: "ミュートを変更できませんでした")
            }
        }
    }

    /// ハッシュタグのミュートを解除する。除いた投稿は戻さず、読み込み直したときに戻る。ユーザーのミュートの解除と同じ。
    /// 解く条件は、解除するときにフィルターを読み直して決める。メニューを組んだときに覚えていた条件で消すと、
    /// その後に別の端末やwebで同じフィルターに足した条件まで、フィルターごと消してしまうため。もうミュートしていなければ、何も消さない。
    private func unmuteHashtag(_ name: String) {
        let client = client
        logger.info("hashtag unmute")
        tasks.run(key: "hashtagMute:\(name)", .skippingWhileRunning, .action) { [weak self, now] in
            guard let self else { return }
            do {
                serverFilters.reload(purpose: .action)
                if let muted = HashtagMute.find(name, in: try await serverFilters.latest(), now: now()) {
                    try await muted.unmute(client: client)
                    serverFilters.reload(purpose: .action)
                }
                excludeInLists(tag: name, excluded: false)
                notices.showTransient(Notice(id: "hashtag.muteChanged", kind: .success, title: "#\(name)のミュートを解除しました"), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
            } catch {
                logger.error("hashtag unmute failed: \(SciaLog.describe(error), privacy: .public)")
                handle(error, title: "ミュートを変更できませんでした")
            }
        }
    }

    private func excludeInLists(tag name: String, excluded: Bool) {
        for feed in feeds {
            feed.setTag(name, excluded: excluded)
        }
        notifications.setTag(name, excluded: excluded)
    }

    /// 期限を付けたハッシュタグのミュートが切れたら、フィルターを読み直し、もうミュートしていなければ、また足すようにする。ユーザーのミュートと同じく、少し余裕を見てから読む。
    private func includeAfterHashtagMuteExpires(_ name: String, duration: Duration) {
        let serverFilters = serverFilters
        // ミュートし直したら、前の期限の待ちを止めて待ち直す。
        tasks.run(key: "muteExpiry:tag:\(name)", .replacing, .display) { [weak self, clock, now] in
            do {
                try await clock.sleep(for: duration + .seconds(60))
                // 覚えているフィルターも新しくし、次に開くメニューでミュートが明けたことを出す。
                serverFilters.reload(purpose: .display)
                guard HashtagMute.find(name, in: try await serverFilters.latest(), now: now()) == nil else { return }
                self?.excludeInLists(tag: name, excluded: false)
            } catch is CancellationError {
                // セッションを止めたか、同じハッシュタグをミュートし直した。
            } catch {
                self?.logger.error("filters reload after hashtag mute expired failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// ユーザーのメニューのメンション、ハンドルとその一部のコピー、関係の項目。メンションは、編集の途中でも編集中の本文に入れる。
    private var userMenuActions: UserMenuActions {
        UserMenuActions(
            mention: { [weak self] target in
                self?.resolveIdentity(of: target, failureTitle: "メンションできませんでした") { _, acct in
                    UserAction.mention.record()
                    self?.composer.mention(acct)
                }
            },
            copy: { [weak self] target, part, notify in
                let failureTitle = switch part {
                case .handle: "ハンドルをコピーできませんでした"
                case .username: "ユーザー名をコピーできませんでした"
                case .server: "サーバーをコピーできませんでした"
                }
                self?.resolveIdentity(of: target, failureTitle: failureTitle) { _, acct in
                    guard let self else { return }
                    UIPasteboard.general.string = UserHandle(acct: acct, localServer: self.credential.server).text(of: part)
                    notify()
                }
            },
            localServer: credential.server,
            resolveTarget: { [weak self] target in
                guard let self else { throw CancellationError() }
                let found = try await self.identity(of: target)
                return UserIdentity(id: found.id, acct: found.acct)
            },
            loadRelation: { [weak self] target, identity in
                try await self?.relation(of: target, identity: identity)
            },
            knownRelation: { [weak self] target in
                self?.knownRelation(of: target)
            },
            reloadRelations: { [weak self] ids in
                self?.reloadRelations(ids)
            },
            changeRelation: { [weak self] change, relation in
                self?.confirmChanging(change, of: relation)
            },
            editNote: { [weak self] relation in
                self?.presentNoteEditor(for: relation)
            },
            report: { [weak self] accountID, acct, statusID in
                self?.presentReport(accountID: accountID, acct: acct, statusID: statusID)
            },
            addToList: { [weak self] target in
                self?.resolveIdentity(of: target, failureTitle: "リストに追加できませんでした") { id, acct in
                    self?.presentListMembership(accountID: id, acct: acct)
                }
            },
            accounts: accounts
        )
    }

    /// ユーザーのメニューの相手のIDと`acct`。リンクから選んだ相手は、プロフィールのURLで引く。見つからなければ`ProfileNotFound`を投げる。
    private func identity(of target: UserMenuTarget) async throws -> (id: String, acct: String) {
        switch target {
        case .account(let id, let acct):
            return (id, acct)
        case .profileURL(let url, let shownAcct):
            let client = client
            guard let account = try await accounts.resolve(.profileURL(url), search: { try await client.resolveAccount(at: url) }) else {
                logger.error("user menu target not found host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash))")
                throw ProfileNotFound(acct: shownAcct)
            }
            return (account.id, account.acct)
        }
    }

    /// 相手のIDと`acct`を決めて`proceed`に渡す。決められなければ知らせて、`proceed`を呼ばない。
    /// 探している途中に選び直したら、前のものは止めて結果を使わない。投稿欄と文字のコピーは見ている画面によらないので、待つ間に画面を移っても使う。
    private func resolveIdentity(of target: UserMenuTarget, failureTitle: String, proceed: @escaping @MainActor (String, String) -> Void) {
        if case .account(let id, let acct) = target {
            identityLookup.cancel()
            proceed(id, acct)
            return
        }
        identityLookup.start(.action, debugDelayed { [weak self] in
            guard let self else { throw CancellationError() }
            return try await identity(of: target)
        }, isStillWanted: { true }) { [weak self] result in
            switch result {
            case .success(let identity):
                proceed(identity.id, identity.acct)
            case .failure(let error):
                self?.logger.error("user menu target resolve failed: \(SciaLog.describe(error), privacy: .public)")
                self?.handle(error, title: failureTitle)
            }
        }
    }

    /// ユーザーのメニューの関係の項目のために、相手との関係を読む。自分のメモを出すため、自分との関係も読む。
    /// 読んだ関係は覚えておき、次にメニューを開いたときと、開き直したプロフィールで使う。
    private func relation(of target: UserMenuTarget, identity: UserIdentity) async throws -> UserRelation? {
        // リンクのメンションは、相手を探すまでIDが分からず、メニューを開いたときにまとめて読み直せないため、ここで読み直す。
        if case .profileURL = target {
            profiles.relationships.reload([identity.id], purpose: .action)
        }
        guard let relationship = try await profiles.relationships.relationship(identity.id) else {
            throw ProfileNotFound(acct: identity.acct)
        }
        return UserRelation(accountID: identity.id, acct: identity.acct, relationship: relationship)
    }

    /// 相手のIDが分かっていて、自分か、関係を覚えている相手なら、その関係。メニューを組むときに、読まずにその場で関係の項目を組むのに使う。
    private func knownRelation(of target: UserMenuTarget) -> KnownRelation? {
        guard case .account(let id, let acct) = target else { return nil }
        let relation = profiles.relationships[id].map { UserRelation(accountID: id, acct: acct, relationship: $0) }
        guard id != credential.accountID else { return .myself(relation) }
        return relation.map { .relation($0) }
    }

    /// メニューに出る人の関係を、まとめて1回で読み直す。別の端末で変えた関係も、次に開いたときから反映する。
    private func reloadRelations(_ ids: [String]) {
        // 関係を覚えていない人は、開いたメニューがこの読み直しを待つので、操作として送る。
        profiles.relationships.reload(ids, purpose: .action)
    }

    /// フォローを外す、リクエストを取り消す、ブロックは、押し間違えに備えて確かめてから送る。プロフィール画面のフォローのボタンと同じく、フォローとミュートは確かめずに送る。
    private func confirmChanging(_ change: UserRelationChange, of relation: UserRelation) {
        guard let confirmation = Confirmation.relationChange(change, acct: relation.acct, endorsed: relation.relationship.endorsed) else {
            send(change, to: relation)
            return
        }
        topViewController.present(UIAlertController(confirmation, preferredStyle: .alert) { [weak self] _ in
            self?.send(change, to: relation)
        }, animated: true)
    }

    /// 関係の変更を送り、結果を開いているプロフィールに反映する。ミュートとブロックは、Mastodonのドキュメントに従い、ホームと通知の一覧からも相手を除く。
    private func send(_ change: UserRelationChange, to relation: UserRelation) {
        let client = client
        let id = relation.accountID
        logger.info("user relation change: \(String(describing: change), privacy: .public)")
        // 送り終える前にメニューを開き直すと、サーバーからは前の関係が読めるため、同じ相手への変更は送り終えるまで重ねて送らない。
        tasks.run(key: "relation:\(id)", .skippingWhileRunning, .action) { [weak self] in
            guard let self else { return }
            do {
                let relationship = switch change {
                case .follow: try await client.follow(id)
                case .unfollow, .cancelFollowRequest: try await client.unfollow(id)
                case .showReblogs(let shows): try await client.follow(id, reblogs: shows)
                case .notify(let notifies): try await client.follow(id, notify: notifies)
                case .endorse(true): try await client.endorse(id)
                case .endorse(false): try await client.unendorse(id)
                case .mute(let duration): try await client.mute(id, duration: duration)
                case .unmute: try await client.unmute(id)
                case .block: try await client.block(id)
                case .unblock: try await client.unblock(id)
                }
                apply(relationship, after: change)
            } catch {
                logger.error("user relation change failed: \(SciaLog.describe(error), privacy: .public)")
                handle(error, title: change.failureTitle)
            }
        }
    }

    private func apply(_ relationship: Relationship, after change: UserRelationChange) {
        profiles.apply(relationship, reloadsAccount: change.changesFollow)
        switch change {
        case .mute, .unmute, .block, .unblock:
            excludeInLists(relationship)
            if case .mute(let duration?) = change {
                includeAfterMuteExpires(relationship.id, duration: duration)
            }
        case .follow, .showReblogs, .notify:
            break
        case .unfollow, .cancelFollowRequest, .endorse:
            break
        }
        // 紹介を変えたときと、サーバーが紹介も消すフォローの解除とブロックのあとは、開いている自分のプロフィールの紹介しているユーザーを読み直す。
        switch change {
        case .endorse, .unfollow, .block:
            profiles.reloadFeatured(of: credential.accountID)
        case .follow, .cancelFollowRequest, .showReblogs, .notify, .mute, .unmute, .unblock:
            break
        }
        notices.showTransient(Notice(id: "user.relationChanged", kind: .success, title: change.doneTitle(relationship)), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    /// 相手のプロフィールに書く、自分にしか見えないメモのシートを開く。保存したら、シートを閉じて知らせ、開いているその人のプロフィールにも反映する。
    private func presentNoteEditor(for relation: UserRelation) {
        let client = client
        let editor = AccountNoteEditor(accountID: relation.accountID, note: relation.relationship.note) { id, comment in
            try await client.setNote(id, comment: comment)
        }
        logger.info("account note sheet opened (empty: \(relation.relationship.note.isEmpty, privacy: .public))")
        let controller = AccountNoteViewController(editor: editor, acct: relation.acct, tasks: tasks.child())
        controller.onSaved = { [weak self] relationship in
            guard let self else { return }
            profiles.apply(relationship, reloadsAccount: false)
            let title = relationship.note.isEmpty ? "メモを消しました" : "メモを保存しました"
            notices.showTransient(Notice(id: "user.noteSaved", kind: .success, title: title), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
        }
        controller.onError = { [weak self] error, title in self?.handle(error, title: title) }
        topViewController.present(controller.wrappedInNavigation(), animated: true)
    }

    /// 通報のシートを開く。送れたら、シートを閉じて知らせる。
    private func presentReport(accountID: String, acct: String, statusID: String?) {
        let client = client
        let draft = ReportDraft(accountID: accountID, acct: acct, statusID: statusID, api: ReportDraft.API(
            rules: { try await client.instanceRules() },
            submit: { try await client.report($0) }
        ))
        logger.info("report sheet opened (status: \(statusID != nil, privacy: .public))")
        let sheet = ReportView.sheet(draft: draft) { [weak self] in
            self?.logger.info("report submitted")
            self?.notices.showTransient(Notice(id: "user.reported", kind: .success, title: "通報しました"), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
        }
        topViewController.present(sheet, animated: true)
    }

    // MARK: - リスト

    /// ユーザーのメニューの「リストに追加」のシートを開く。決まりはdocs/lists.mdの「リストに追加」にある。
    private func presentListMembership(accountID: String, acct: String) {
        let client = client
        let model = ListMembershipModel(isMyself: accountID == credential.accountID, api: ListMembershipModel.API(
            lists: { try await client.lists() },
            listsContaining: { try await client.lists(containing: accountID) },
            relationship: {
                guard let relationship = try await client.relationships([accountID]).first else { throw ProfileNotFound(acct: acct) }
                return relationship
            },
            add: { try await client.addAccounts([accountID], toList: $0) },
            remove: { try await client.removeAccounts([accountID], fromList: $0) },
            follow: { try await client.follow(accountID) },
            create: { try await client.createList(title: $0) }
        ), tasks: tasks.child()) { [weak self] in
            self?.reportUnauthorized()
        }
        model.onFailure = { [weak self] operation, reason in
            self?.reportListFailure(title: operation.failureTitle, reason: reason)
        }
        // 開いているその人のプロフィールと、覚えている関係にも入れる。
        model.onFollowed = { [weak self] relationship in self?.profiles.apply(relationship, reloadsAccount: true) }
        logger.info("list membership sheet opened")
        let sheet = ListMembershipView.sheet(model: model, acct: acct) { [weak self, weak model] onCreate in
            guard let model else { return }
            self?.listEditor.presentCreate(create: { try await model.create(title: $0) }, onCreate: onCreate)
        }
        topViewController.present(sheet, animated: true)
        model.load()
    }

    /// リストのメンバーの画面を開いた一覧に積む。決まりはdocs/lists.mdの「メンバー」にある。
    private func openListMembers(listID: String, title: String, from source: UIViewController) {
        let (controller, viewController) = AccountListController.make(kind: .listMembers(listID: listID), client: client, tasks: tasks.child()) { [weak self] in
            self?.reportUnauthorized()
        }
        viewController.navigationItem.subtitle = title
        controller.onMemberFailure = { [weak self] title, error in
            self?.tasks.run(.action) { [weak self] in
                guard let self else { return }
                reportListFailure(title: title, reason: await listFailureReason(for: error))
            }
        }
        let add = UIBarButtonItem(title: "メンバーを追加", image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self, weak controller] _ in
            guard let controller else { return }
            self?.presentListMemberSearch(for: controller)
        })
        add.isEnabled = false
        controller.onLoadedChange = { [weak add] in add?.isEnabled = $0 }
        viewController.screenBarItems = [add]
        UserAction.openAccountList.record()
        configure(viewController)
        source.navigationController?.pushViewController(viewController, animated: true)
        controller.start(purpose: .action)
    }

    /// メンバーの画面の＋で、フォローしている人を探して足すシートを開く。
    private func presentListMemberSearch(for members: AccountListController) {
        let client = client
        let sheet = ListMemberSearchView.sheet(
            search: { try await client.searchFollowedAccounts($0, limit: 20) },
            initialMemberIDs: members.accountIDs
        ) { [weak members] account, adds, completion in
            guard let members else { return completion(false) }
            members.changeMember(account, adds: adds, completion: completion)
        }
        topViewController.present(sheet, animated: true)
    }

    /// 設定の画面を出す。閉じる途中の画面には重ねられないため、閉じる途中の画面を飛ばして重ねる。
    /// - Parameter appearanceGroup: `page`が「投稿の見た目」のとき、その上に重ねておく分類の画面。
    private func presentSettings(opening page: SettingsPage?, appearanceGroup: AppearanceGroup.ID? = nil) {
        rootViewController.frontmostPresented.presentSettings(
            instance: credential.instance,
            account: credential.handle,
            diagnostics: diagnostics,
            tabIcons: profileTabIcons,
            lists: settingsListActions,
            openInAppBrowserHeight: { [weak self] in self?.open(.inAppBrowserHeight(returningTo: .interaction)) },
            opening: page,
            appearanceGroup: appearanceGroup,
            onShownChange: { [weak self] in self?.settingsShownChanged($0) }
        )
    }

    /// 設定の画面が1枚でも出ている間は、一覧が設定の変更で描き直すのを溜め、すべて閉じたときにまとめて描き直させる。
    /// 設定の画面ごとに、出たときと消えたときに1回ずつ呼ぶ。
    func settingsShownChanged(_ isShown: Bool) {
        shownSettingsCount = max(shownSettingsCount + (isShown ? 1 : -1), 0)
        for timeline in timelines.allObjects {
            timeline.holdsSettingsChanges = shownSettingsCount > 0
        }
    }

    /// 重ねた画面を閉じてホームのタブの一覧を出し、本物のタイムラインの上に、アプリ内のSafariの高さを選ぶシートを出す。
    /// 選んだ高さの段にシートを置くので、シートの上にホームがどのくらい見えるかを、実物のまま見比べられる。
    /// ホームに積んだ画面（スレッドやプロフィール）は閉じて一覧まで戻す。積んだ画面の上では、一覧がどのくらい見えるかを比べられないため。
    /// ホームのタブを無効にしていれば、選んでいるタブの一覧の上に出す。
    /// - Parameter page: 閉じたときに開き直す設定の画面。nilなら開き直さない。
    private func showInAppBrowserHeight(returningTo page: SettingsPage?) {
        rootViewController.closeAllScreens { [weak self] in
            guard let self, let window = rootViewController.viewIfLoaded?.window else { return }
            tabs.show(.home)
            tabs.selectedNavigation?.popToRootViewController(animated: false)
            let sheet = InAppBrowserHeightSheet(settings: AppDependencies.settings, window: window) { [weak self] in
                // 上にアプリ内のSafariを重ねていれば一緒に閉じるので、閉じたことが届くよう、まとめて閉じる経路を通す。
                self?.rootViewController.dismissPresentedScreens(animated: true) {
                    if let page { self?.open(.settings(page)) }
                }
            }
            // アプリ内のSafariと同じく、覆う高さを一覧の下の余白と見えた投稿の判定に使わせる。
            sheet.onObscuredHeightChange = { [weak self] height in
                self?.heightPickerObscuredHeight = height
                self?.applyObscuredBottomHeight()
            }
            rootViewController.present(sheet, animated: true)
        }
    }

    /// タブの並びの画面で、リストを作る、消す。
    var settingsListActions: SettingsListActions {
        SettingsListActions { [weak self] in
            self?.listEditor.presentCreate()
        } delete: { [weak self] id, title in
            self?.listEditor.confirmDelete(listID: id, title: title)
        }
    }

    /// ミュートかブロックしている相手を、投稿と通知の一覧から除く。どちらでもなくなったら、また足すようにする。
    private func excludeInLists(_ relationship: Relationship) {
        // 引用元は一覧から除かず、届いたときからミュートかブロックしていたのと同じく、押して開くまで隠す。
        let concealedAs: Quote.State? = relationship.blocking ? .blockedAccount : relationship.muting ? .mutedAccount : nil
        changeQuoteSources(.account(relationship.id)) { $0.setAccount(relationship.id, concealedAs: concealedAs) }
        // ユーザーのハッシュタグの一覧は、その人の投稿だけを並べるため、プロフィール画面の一覧と同じく除かない。
        for feed in feeds where !feed.feed.isAccountHashtag {
            feed.setAccount(relationship.id, excluded: relationship.blocking || relationship.muting)
        }
        notifications.setAccount(relationship.id, excluded: relationship.blocking || (relationship.muting && relationship.mutingNotifications))
        for list in savedLists {
            list.setAccount(relationship.id, excluded: relationship.blocking || relationship.muting)
        }
        if relationship.blocking || relationship.muting {
            searches.excludeAccount(relationship.id)
        }
    }

    /// 期間を決めたミュートは、期限が来たら関係を読み直し、ミュートが明けていれば、一覧から除くのをやめる。
    /// 読み直すのは、その間にブロックしたり、期間を選び直したりしていることがあるため。読めなければ、起動し直すまで除いたままにする。
    /// Mastodonは期限の時刻に予約したジョブ（`DeleteMuteWorker`）でミュートを消すため、ちょうどの時刻ではまだ残っていることがある。1分おいてから読む。
    private func includeAfterMuteExpires(_ accountID: String, duration: Duration) {
        let relationships = profiles.relationships
        tasks.run(key: "muteExpiry:account:\(accountID)", .replacing, .display) { [weak self, clock] in
            do {
                try await clock.sleep(for: duration + .seconds(60))
                // 覚えている関係も新しくし、次に開くメニューでミュートが明けたことを出す。
                relationships.reload([accountID], purpose: .display)
                guard let relationship = try await relationships.relationship(accountID), !relationship.muting else { return }
                self?.excludeInLists(relationship)
            } catch is CancellationError {
                // セッションを止めたか、同じ相手をミュートし直した。
            } catch {
                self?.logger.error("relationship reload after mute expired failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 編集か削除して書き直している途中で返信か引用を選んだら、やめてよいか聞いてから始める。どちらでもなければすぐ始める。
    /// 返信と引用は書いた本文を残して返信先や引用元を付け替えるが、編集と書き直しの本文は元の投稿のものなので、引き継がない。
    private func confirmLeavingEdit(starting: String, _ proceed: @escaping () -> Void) {
        guard let confirmation = Confirmation.leavingEdit(starting: starting, draft: composer.model) else {
            proceed()
            return
        }
        topViewController.present(UIAlertController(confirmation, preferredStyle: .alert) { [weak self] _ in
            // 送っている間はやめず、返信も始めない。送り終えれば空に戻るので、返信はそのあと選び直してもらう。
            guard self?.composer.cancelStatusEdit() == true else { return }
            proceed()
        }, animated: true)
    }

    /// 自分が引用できるかが分かっていれば、すぐ引用を始める。公開とハッシュタグのストリーミングで届いた投稿は、
    /// ログインしていない人向けの形で届き、引用できるかが分からないので、読み直して確かめてから始める。
    /// 読めなかったら、編集を始められなかったときと同じく、チップの列に出す。
    private func startQuoting(_ status: Status) {
        guard status.displayed.quoteApproval?.availability == .unverified else {
            beginQuoting(status)
            return
        }
        let client = client
        let target = status.displayed
        tasks.run(.action) { [weak self] in
            do {
                let refetched = try await client.status(target.id)
                guard let self else { return }
                switch refetched.quoteApproval?.availability {
                case .automatic, .manual:
                    beginQuoting(status)
                case .denied(followersOnly: true):
                    presentRefusal(.quoteDenied(followersOnly: true))
                case .denied(followersOnly: false), .unverified, nil:
                    presentRefusal(.quoteDenied(followersOnly: false))
                }
            } catch {
                guard let self else { return }
                let title = "引用を始められませんでした"
                logger.error("quote check failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason, subject: OperationStatus.Subject(status))
                showFailureNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    private func beginQuoting(_ status: Status) {
        confirmLeavingEdit(starting: "引用") { [weak self] in self?.confirmQuoting(status) }
    }

    /// 下書きに添付か投票があれば、外してよいか聞いてから引用を始める。なければすぐ始める。
    /// Mastodonは引用に添付と投票を付けられないため。本文は残す。
    private func confirmQuoting(_ status: Status) {
        guard let confirmation = Confirmation.quoting(draft: composer.model) else {
            composer.quote(status)
            return
        }
        topViewController.present(UIAlertController(confirmation, preferredStyle: .alert) { [weak self] _ in
            self?.composer.quote(status)
        }, animated: true)
    }

    /// 編集の元にする本文をサーバーから取得し、取得できたら投稿欄で編集を始める。同じ投稿を編集している途中なら、読み直さずに投稿欄を開く。
    /// 読めなかったら、お気に入りの失敗と同じく、チップの列に出す。
    private func startEditing(_ status: Status) {
        let target = status.displayed
        if composer.model.editedStatus?.id == target.id {
            composer.beginEditing()
            return
        }
        let client = client
        tasks.run(.action) { [weak self] in
            do {
                let source = try await client.statusSource(target.id)
                self?.confirmEditing(target, source: source)
            } catch {
                guard let self else { return }
                let title = "編集を始められませんでした"
                logger.error("edit source failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason, subject: OperationStatus.Subject(status))
                showFailureNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    /// 書き直しの元にする本文をサーバーから取得し、取得できたら、送ると元の投稿を削除することを確かめてから、投稿欄で書き直しを始める。
    /// 同じ投稿を書き直している途中なら、読み直さずに投稿欄を開く。読めなかったら、編集と同じく、チップの列に出す。
    private func startRedrafting(_ status: Status) {
        let target = status.displayed
        if composer.model.redraft?.status.id == target.id {
            composer.beginEditing()
            return
        }
        let client = client
        tasks.run(.action) { [weak self] in
            do {
                let source = try await client.statusSource(target.id)
                self?.confirmRedrafting(target, source: source)
            } catch {
                guard let self else { return }
                let title = "書き直しを始められませんでした"
                logger.error("redraft source failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason, subject: OperationStatus.Subject(status))
                showFailureNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    /// 本文を読んでから聞く。先に聞くと、読んでいる間に書いたものを、聞かずに捨ててしまうため。
    private func confirmRedrafting(_ status: Status, source: StatusSource) {
        topViewController.present(UIAlertController(Confirmation.redrafting(status, draft: composer.model), preferredStyle: .alert) { [weak self] _ in
            self?.composer.redraft(status, source: source)
        }, animated: true)
    }

    // MARK: - 予約投稿

    /// 予約できた。予約はタイムラインに何も出ず、うまくいったことが画面の変化で見えないため、チップで知らせる。押すと予約の一覧を開く。
    fileprivate func didSchedule(_ status: ScheduledStatus) {
        scheduled.didSchedule(status)
        let title = "\(ScheduleDateText.shortTitle(for: status.scheduledAt, now: now(), calendar: .autoupdatingCurrent))に予約しました"
        let notice = Notice(id: "compose.scheduled", kind: .success, title: title, action: .disclosure(hint: "予約した投稿の一覧を表示します。") { [weak self] in
            self?.showScheduledStatuses()
        })
        notices.showTransient(notice, duration: AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration))
    }

    /// 予約した投稿の一覧を開く。タブに並べていればそのタブを開き、無効にしていれば、閉じるボタンを付けて手前に重ねる。
    private func showScheduledStatuses() {
        if tabs.placement.location(of: .scheduled) != .disabled {
            tabs.show(.scheduled)
            return
        }
        let list = ScheduledStatusesController(client: client, tasks: tasks.child(), myAccount: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await myAccount()
        }) { [weak self] in self?.reportUnauthorized() }
        list.viewController.mediaTransfers = mediaTransfers
        list.viewController.notices = notices
        list.onRewrite = { [weak self, weak list] status in
            // 投稿欄は一覧の下にあるので、書き直すときは一覧を閉じてから聞く。
            list?.viewController.dismiss(animated: true) {
                self?.confirmRewriting(status)
            }
        }
        presentedScheduled = list
        let navigation = UINavigationController(rootViewController: list.viewController)
        list.viewController.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak navigation] _ in
            navigation?.dismiss(animated: true)
        })
        topViewController.present(navigation, animated: true)
    }

    /// 書きかけの下書きがあれば捨ててよいかを聞いてから、予約した投稿の書き直しを始める。
    private func confirmRewriting(_ status: ScheduledStatus) {
        guard let confirmation = Confirmation.rewriting(draft: composer.model) else {
            composer.rewrite(status)
            return
        }
        topViewController.present(UIAlertController(confirmation, preferredStyle: .alert) { [weak self] _ in
            self?.composer.rewrite(status)
        }, animated: true)
    }

    /// 書き直した投稿を送れたので、元の予約を取り消す。取り消せなければ、両方投稿されないよう知らせて一覧を開く。
    /// もう投稿されていたら（404）、取り消すものはないので何もしない。
    private func cancelRewrittenSchedule(_ id: ScheduledStatus.ID) {
        logger.info("rewritten schedule cancel start")
        // 書き直した投稿を送ってすぐバックグラウンドへ移っても、取り消し終えるまでアプリを止めないよう頼む。取り消せないまま元の予約が投稿されないようにするため。
        let endBackgroundTime = BackgroundTime.request("cancel rewritten schedule")
        let task = tasks.run(.action) { [weak self, client] in
            defer { endBackgroundTime() }
            do {
                try await client.cancelScheduledStatus(id)
            } catch let error as MastodonAPIError where error.statusCode == 404 {
                self?.logger.info("rewritten schedule already gone")
            } catch {
                guard let self, !(error is CancellationError) else { return }
                logger.error("rewritten schedule cancel failed: \(SciaLog.describe(error), privacy: .public)")
                if let error = error as? MastodonAPIError, error.isUnauthorized {
                    reportUnauthorized()
                }
                let alert = UIAlertController(title: "元の予約を取り消せませんでした", message: "書き直した投稿は送りましたが、元の予約が残っています。両方投稿されないよう、予約の一覧から取り消してください。\n\(ErrorPresentation(error).text)", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "予約の一覧を開く", style: .default) { [weak self] _ in self?.showScheduledStatuses() })
                alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
                topViewController.present(alert, animated: true)
                return
            }
            self?.logger.info("rewritten schedule cancel done")
            self?.scheduled.didCancel(id)
        }
        if task == nil {
            endBackgroundTime()
        }
    }

    /// 書きかけの下書きがあれば捨ててよいかを、投票の付いた投稿なら締め切りがずれることを、聞いてから編集を始める。どちらもなければすぐ始める。
    /// 本文を読んでから聞く。先に聞くと、読んでいる間に書いたものを、聞かずに捨ててしまうため。
    private func confirmEditing(_ status: Status, source: StatusSource) {
        switch Confirmation.editing(status, draft: composer.model, now: now()) {
        case .proceed:
            composer.edit(status, source: source)
        case .refuse(let text):
            presentRefusal(text)
        case .confirm(let confirmation):
            topViewController.present(UIAlertController(confirmation, preferredStyle: .alert) { [weak self] _ in
                guard let self else { return }
                // 聞いている間に締め切りが近づいたら、投票なしで送って投票を消さないよう、編集を始めない。
                if !status.canBeEdited(now: now()) {
                    presentRefusal(.pollTooClose)
                } else {
                    composer.edit(status, source: source)
                }
            }, animated: true)
        }
    }

    /// 削除は元に戻せないので、確かめてから送る。
    private func confirmDeleting(_ status: Status) {
        topViewController.present(UIAlertController(Confirmation.deleting, preferredStyle: .alert) { [weak self] _ in
            self?.delete(status)
        }, animated: true)
    }

    /// 消えたらどの一覧からも除く。編集か削除して書き直している投稿を消したら、編集と書き直しもやめる。
    /// 書き直しをやめるのは、添付も消え、書き直した投稿に付けられなくなるため。
    /// 失敗は押し直せば済むので、お気に入りの失敗と同じく、チップの列に出す。
    private func delete(_ status: Status) {
        UserAction.deleteStatus.record()
        let target = status.displayed
        let client = client
        // 送り終える前に確かめ直して押しても、同じ削除を重ねて送らない。
        tasks.run(key: "delete:\(target.id)", .skippingWhileRunning, .action) { [weak self] in
            do {
                // web UIと同じく、添付もすぐ消す。送らないと、削除して書き直すために、サーバーが添付を1日ほど残すため。
                try await client.deleteStatus(target.id, deleteMedia: true)
                guard let self else { return }
                removeDeletedStatus(target.id)
                if composer.model.editedStatus?.id == target.id {
                    composer.cancelStatusEdit()
                }
                // 送っている間はやめられないので、送るのをやめられるところでやめさせる。
                if composer.model.redraft?.status.id == target.id, !composer.cancelStatusEdit() {
                    composer.model.redraftedStatusWasDeleted(target.id, stopsRedrafting: true)
                }
            } catch {
                guard let self else { return }
                let title = "投稿を削除できませんでした"
                logger.error("delete failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason, subject: OperationStatus.Subject(status))
                showFailureNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    /// 削除した自分の投稿を、どの一覧からも除く。
    private func removeDeletedStatus(_ id: Status.ID) {
        for feed in feeds {
            feed.removeStatus(id)
        }
        notifications.removeStatus(id)
        for list in savedLists {
            list.removeStatus(id)
        }
        profiles.removeStatus(id)
        threads.removeStatus(id)
        searches.removeStatus(id)
        changeQuoteSources(.status(id)) { $0.delete(id) }
    }

    /// 承認か却下が済んだら、サーバーと同じく、そのユーザーからのリクエストの通知を一覧から除く。
    /// 404は、承認を待っているリクエストがもうないこと（相手が取り消した、ほかの端末で片づけたなど）なので、済んだときと同じく除く。
    /// 失敗は押し直せば済むので、お気に入りの失敗と同じく、チップの列に出す。
    private func answerFollowRequest(_ decision: FollowRequestDecision, to request: MastodonNotification) {
        let account = request.account
        let client = client
        tasks.run(.action) { [weak self] in
            do {
                switch decision {
                case .authorize: _ = try await client.authorizeFollowRequest(from: account.id)
                case .reject: _ = try await client.rejectFollowRequest(from: account.id)
                }
                self?.notifications.removeFollowRequests(answering: request)
            } catch let error as MastodonAPIError where error.statusCode == 404 {
                guard let self else { return }
                logger.info("follow request \(String(describing: decision), privacy: .public) not found")
                notifications.removeFollowRequests(answering: request)
            } catch {
                guard let self else { return }
                let title = switch decision {
                case .authorize: "フォローリクエストを承認できませんでした"
                case .reject: "フォローリクエストを却下できませんでした"
                }
                logger.error("follow request \(String(describing: decision), privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason)
                showFailureNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    /// 通知を削除し、済んだら一覧から除く。404は、通知がもうないこと（ほかの端末で削除したなど）なので、済んだときと同じく除く。
    /// 失敗は押し直せば済むので、お気に入りの失敗と同じく、チップの列に出す。
    private func dismissNotification(_ notification: MastodonNotification) {
        UserAction.dismissNotification.record()
        let client = client
        tasks.run(.action) { [weak self] in
            do {
                try await client.dismissNotificationGroup(notification.groupKey)
                self?.notifications.removeNotification(notification)
            } catch let error as MastodonAPIError where error.statusCode == 404 {
                guard let self else { return }
                logger.info("dismissed notification not found")
                notifications.removeNotification(notification)
            } catch {
                guard let self else { return }
                let title = "通知を削除できませんでした"
                logger.error("dismiss notification failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason)
                showFailureNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    private static let linkTitleActivityID = "compose.linkTitle"

    /// 投稿欄でタイトルを読んでいる間は、読んでいるURLの上にきらめきを流すほか、「操作の状況」の進行中にも並べる。
    private func linkTitleActivityDidChange() {
        if composer.isLoadingLinkTitle {
            operationStatus.update(OperationStatus.Activity(id: Self.linkTitleActivityID, title: "タイトルを読み込み中"))
        } else {
            operationStatus.end(Self.linkTitleActivityID)
        }
    }

    /// 失敗を「操作の状況」に残し、数秒で消えるチップで知らせる。
    private func linkTitleDidFail(_ failure: LinkTitleFailure) {
        linkTitleActivityDidChange()
        let reason = switch failure {
        case .unreadable(let error as URLError): ErrorPresentation(error)
        case .unreadable(let error as HTTPStatusError): ErrorPresentation(message: "リンク先のページを読み込めませんでした。", code: "HTTP \(error.statusCode)")
        case .unreadable: ErrorPresentation(message: "リンク先のページを読み込めませんでした。", code: nil)
        case .noTitle: ErrorPresentation(message: "リンク先のページにタイトルがありませんでした。", code: nil)
        }
        operationStatus.recordFailure(title: failure.title, reason: reason)
        notices.showTransient(duration: AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration)) { [weak self] _ in
            .linkTitleFailed(failure) { self?.presentAlert(title: failure.title, message: reason.text) }
        }
    }

    /// 押し直せば済む失敗を、チップの列に数秒出す。押すと理由が出る。
    private func showFailureNotice(_ notice: Notice) {
        notices.showTransient(notice, duration: AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration))
    }

    /// 押し直せば済む失敗なので、操作を止めるアラートにせず、チップの列に数秒で消えるチップを出し、押すと理由を出す。
    /// 消えたあとも確かめられるよう、「最近の失敗」に残す。
    /// - Parameter onSuccess: サーバーが受け付けたら呼ぶ。同じ操作の結果を待っている間に押されて送らなかったときは呼ばない。
    /// 行に見える変化がない操作（ブックマーク、会話のミュート、固定）が済んだことを知らせる。メニューを閉じると、変わったことが見えないため。
    /// お気に入りとブーストは、行の光の動きで分かるので知らせない。決まりはdocs/object-actions.mdの「結果の知らせ」にある。
    private func showToggledNotice(_ title: String) {
        notices.showTransient(Notice(id: "status.toggled", kind: .success, title: title), duration: AppDependencies.tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    private func toggle(_ action: StatusInteractions.Action, on status: Status, reblogVisibility: ReblogVisibility = .accountDefault, failureTitle: String, onSuccess: (() -> Void)? = nil) {
        let interactions = interactions
        tasks.run(.action) { [weak self] in
            do {
                guard try await interactions.toggle(action, on: status, reblogVisibility: reblogVisibility) else { return }
                onSuccess?()
            } catch {
                guard let self else { return }
                logger.error("toggle \(String(describing: action), privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: failureTitle, reason: reason, subject: OperationStatus.Subject(status))
                showFailureNotice(.interactionFailure(title: failureTitle) { [weak self] in
                    self?.presentAlert(title: failureTitle, message: reason.text)
                })
            }
        }
    }

    /// 投票の通信の口。デバッグビルドでは、ダミー投稿の投票だけ、通信せずに`DummyPolls`が答える。
    private static func pollOperations(client: MastodonClient) -> PollVoting.Operations {
        #if DEBUG
        PollVoting.Operations(
            vote: { id, choices in
                DummyPolls.isDummy(id) ? try await DummyPolls.vote(id, choices: choices) : try await client.vote(id, choices: choices)
            },
            poll: { id in
                DummyPolls.isDummy(id) ? try await DummyPolls.poll(id) : try await client.poll(id)
            }
        )
        #else
        PollVoting.Operations(client: client)
        #endif
    }

    /// 投票する。投票は取り消せないため、サーバーの結果を待ってから、すべての一覧に反映する。
    /// 失敗したら、選んだ選択肢を残したまま、お気に入りの失敗と同じチップで知らせる。
    private func vote(_ choices: Set<Int>, on status: Status, from timeline: TimelineViewController) {
        guard let pollID = status.displayed.poll?.id else { return }
        UserAction.vote.record()
        let polls = polls
        let title = "投票できませんでした"
        tasks.run(.action) { [weak self, weak timeline] in
            do {
                // ほかの一覧から送った同じ投票の結果を待っているときは送らない。その結果は、送った側がすべての一覧に反映する。
                let sent = try await polls.vote(choices, on: status)
                timeline?.finishVoting(pollID, succeeded: sent)
            } catch {
                timeline?.finishVoting(pollID, succeeded: false)
                guard let self else { return }
                logger.error("vote failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason, subject: OperationStatus.Subject(status))
                showFailureNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    /// 投票の結果を読み直し、すべての一覧に反映する。
    private func refreshPoll(of status: Status, from timeline: TimelineViewController) {
        guard let pollID = status.displayed.poll?.id else { return }
        UserAction.refreshPoll.record()
        let polls = polls
        let title = "投票の結果を読み直せませんでした"
        tasks.run(.action) { [weak self, weak timeline] in
            do {
                try await polls.refresh(status)
                timeline?.finishRefreshingPoll(pollID)
            } catch {
                timeline?.finishRefreshingPoll(pollID)
                guard let self else { return }
                logger.error("poll refresh failed: \(SciaLog.describe(error), privacy: .public)")
                let reason = await failureReason(for: error)
                operationStatus.recordFailure(title: title, reason: reason, subject: OperationStatus.Subject(status))
                showFailureNotice(.interactionFailure(title: title) { [weak self] in
                    self?.presentAlert(title: title, message: reason.text)
                })
            }
        }
    }

    private func handle(_ error: any Error, title: String) {
        guard let apiError = error as? MastodonAPIError, apiError.isUnauthorized else {
            presentAlert(title: title, message: ErrorPresentation(error).text)
            return
        }
        tasks.run(.action) { [weak self] in
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

    private func presentRefusal(_ refusal: RefusalText) {
        presentAlert(title: refusal.title, message: refusal.message)
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
        composeDefaultsTask = tasks.run(.action) { [weak self] in
            guard let self else { return }
            #if DEBUG
            await session.applyComposeDefaults(to: composer.model, adjustingConfiguration: DebugFaults.applyingMediaLimits(to:))
            #else
            await session.applyComposeDefaults(to: composer.model)
            #endif
        }
    }

    func start() {
        hasStarted = true
        // 無効にしている項目は、有効にしたときか開いたときに始める。
        if tabs.placement.location(of: .home) != .disabled {
            home.start(purpose: .action)
        }
        if tabs.placement.location(of: .notifications) != .disabled {
            notifications.start(purpose: .action)
        }
        loadProfileTabIcons(tabs.placement)
        let network = AppDependencies.network
        session.observeRecoveries { network.recoveryCount }
        loadServerVersion()
        loadTabSources()
        announcements.start()
        // 注意書きを最初から開いておくかを一覧に反映する。読めなければ折りたたんだままにし、次に投稿欄で書き始めたときに読み直す。
        tasks.run(.display) { [session] in await session.loadPreferences() }
    }

    /// 原因を絞れるよう、サーバーの版を記録に残す。読めなくても使うのに困らないので、失敗は記録するだけにする。
    private func loadServerVersion() {
        let client = client
        let instance = credential.instance.host() ?? credential.instance.absoluteString
        tasks.run(.display) { [weak self] in
            do {
                let version = try await client.serverVersion()
                self?.logger.info("server instance=\(instance, privacy: .public) version=\(version, privacy: .public)")
                self?.diagnostics.setServerVersion(version)
            } catch {
                self?.logger.info("server version unavailable instance=\(instance, privacy: .public) error=\(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    // MARK: - ログインし直し

    private func reportUnauthorized() {
        session.reportUnauthorized()
    }

    /// トークンが無効だと確かめられ、`session`が自動の通信を止めたら、表示中の内容とアカウントのメニューは残したまま、ログインし直しを促す。
    private func credentialsDidBecomeInvalid() {
        // どの画面にいても見えるよう、チップの列の一番上に段を出す。
        notices.reauthentication = NoticeCenter.Reauthentication(handle: credential.handle, isInProgress: isReauthenticating) { [weak self] in
            self?.reauthenticate()
        }
        for timeline in timelines.allObjects {
            showReauthenticationPrompt(on: timeline)
        }
    }

    /// 一覧の再試行ボタンも、ログインし直しにする。止めた後の再試行は何も読まず、ログインし直すまで読み込めないため。
    private func showReauthenticationPrompt(on viewController: TimelineViewController) {
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
        tasks.run(.action) { [weak self] in
            guard let self else { return }
            await onReauthenticate(self)
            setReauthenticating(false)
        }
    }

    private func setReauthenticating(_ isReauthenticating: Bool) {
        self.isReauthenticating = isReauthenticating
        notices.reauthentication?.isInProgress = isReauthenticating
    }

    /// このセッションで始めた処理を全部止め、以後の結果を捨てる。ログアウト、アカウントの切り替え、窓を閉じたときなど、画面を捨てるときに呼ぶ。
    /// 一覧、開いている画面、投稿欄の送信とアップロード、ストリーミングは、どれも持ち主の子で始めているので、ここで並べなくても止まる。
    func stop() {
        statusBarTicker.clear()
        session.close()
    }

    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { tasks.runningCount }

    /// 他のアプリから開かれたURLの画面を出す。
    func open(_ url: AppURL) {
        switch url {
        case .open(let destination):
            open(destination)
        case .share(let id, let unreadableCount):
            rootViewController.closeScreensForSharedContent { [weak self] in
                self?.receiveSharedMedia(id: id, unreadableCount: unreadableCount)
            }
        case .compose(let text):
            rootViewController.closeScreensForSharedContent { [weak self] in
                self?.receiveSharedText(text)
            }
        }
    }

    /// 共有拡張が作った本文（Safariのページのタイトル、URL、選んだ文の引用）で書き始める。書きかけの下書きがあれば、後ろに足すか、捨てて新しく書くかを聞く。
    /// 一覧の上に重ねた画面を閉じる範囲は、`receiveSharedMedia(id:unreadableCount:)`と同じ。
    private func receiveSharedText(_ text: String) {
        logger.info("shared text received length=\(text.count, privacy: .public)")
        switch Confirmation.shared(.text, draft: composer.model) {
        case .proceed:
            appendSharedText(text)
        case .refuse(let refusal):
            presentRefusal(refusal)
        case .confirm(let confirmation):
            topViewController.present(UIAlertController(confirmation, preferredStyle: .alert) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .append:
                    appendSharedText(text)
                case .discardAndWrite:
                    // 聞いている間に送り始めていたら、捨てずに、受け取った文を足さない。
                    guard composer.discardDraft() else { return }
                    appendSharedText(text)
                case .cancel:
                    break
                }
            }, animated: true)
        }
    }

    /// 書き始めて、本文の後ろに足す。下書きがなくても置き換えずに足すのは、返信の宛先のように自動で入れた本文を残すため。
    /// 足した本文が上限の行数に収まらなければ、投稿欄を広げる。
    private func appendSharedText(_ text: String) {
        // 下書きがあるかを聞いている間に、送り始めていることがある。
        guard !composer.model.isPosting else {
            presentRefusal(.sharedWhilePosting(.text))
            return
        }
        composer.beginEditing(appendingShared: text)
    }

    /// 共有拡張が受け取ったメディアを、投稿欄に添付して書き始める。書きかけの下書きがあれば、足すか、捨てて新しく書くかを聞く。
    /// 一覧の上に重ねた画面は、呼ぶ前に閉じて、投稿欄を見せる（`closeScreensForSharedContent(completion:)`）。
    /// 閉じると失うものがある画面（`StaysForSharedContent`や、書きかけのある画面）は閉じずにその上で聞き、投稿欄は重ねた画面の下で開く。
    /// - Parameter unreadableCount: 共有拡張が受け取れなかった件数。1件も受け取れなかったときは、受け渡しのフォルダーを作らずに開かれる。
    private func receiveSharedMedia(id: UUID, unreadableCount: Int) {
        guard let inbox = SharedMediaInbox.app else {
            logger.error("shared media ignored without app group")
            return
        }
        let files: [URL]
        do {
            files = try inbox.files(id: id)
        } catch where unreadableCount > 0 {
            files = []
        } catch {
            // 同じURLを開き直したときなど、受け取ったファイルをもう消したあと。
            logger.error("shared media not found id=\(id, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
            presentRefusal(.sharedMediaGone)
            return
        }
        let media = files.compactMap(LocalMediaLoader.startCopyingFile)
        logger.info("shared media received count=\(media.count, privacy: .public) of \(files.count, privacy: .public) unreadable=\(unreadableCount, privacy: .public)")
        // 選んだうちの一部が欠けたことは、添付した列を見ても分からないので知らせる。画像か動画でないファイルは、拡張が画像か動画の表現を選んで置くので、普通は届かない。
        let missingCount = unreadableCount + files.count - media.count
        if missingCount > 0 {
            notices.showTransient(.sharedMediaUnreadable(count: missingCount), duration: AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration))
        }
        // 投稿欄の一時ディレクトリへコピーし終えたら、受け渡しのフォルダーから消す。コピーに失敗したものは、添付の失敗として投稿欄に出る。
        // セッションを閉じても止めない。端末の中のコピーで通信せず、途中で止めると受け渡しのフォルダーが消されずに残るため。
        // scialint:disable:next session_task_outside_scope
        Task(.withoutRequests) {
            for item in media {
                _ = try? await item.load()
            }
            inbox.remove(id: id)
        }
        guard !media.isEmpty else { return }
        let decision = Confirmation.shared(.media(allImages: media.allSatisfy { $0.kind == .image }), draft: composer.model)
        switch decision {
        case .proceed:
            attachSharedMedia(media, unattachable: RefusalText.sharedMediaUnattachable(draft:))
        case .refuse(let refusal):
            discardSharedMedia(media)
            presentRefusal(refusal)
        case .confirm(let confirmation):
            topViewController.present(UIAlertController(confirmation, preferredStyle: .alert) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .append:
                    attachSharedMedia(media, unattachable: RefusalText.sharedMediaUnattachable(draft:))
                case .discardAndWrite:
                    // 聞いている間に送り始めていたら、捨てずに、受け取ったものを足さない。
                    guard composer.discardDraft() else {
                        discardSharedMedia(media)
                        return
                    }
                    attachSharedMedia(media, unattachable: RefusalText.sharedMediaUnattachable(draft:))
                case .cancel:
                    discardSharedMedia(media)
                }
            }, animated: true)
        }
    }

    /// 画面にドロップしたメディアを、読み終えてから投稿欄に足す。読めなかった項目があれば、共有と同じチップで知らせる。
    private func receiveDroppedMedia(_ drop: MediaDrop) {
        let waiting = tasks.run(.action) { [weak self] in
            let (media, missingCount) = await drop.result()
            guard let self, !Task.isCancelled else {
                for item in media {
                    item.discard()
                }
                return
            }
            logger.info("media drop: loaded count=\(media.count, privacy: .public) missing=\(missingCount, privacy: .public)")
            if missingCount > 0 {
                notices.showTransient(.sharedMediaUnreadable(count: missingCount), duration: AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration))
            }
            guard !media.isEmpty else { return }
            attachSharedMedia(media, unattachable: RefusalText.droppedMediaUnattachable(draft:))
        }
        if waiting == nil {
            drop.discard()
        }
    }

    /// 書き始めて、サーバーの上限と既定の閲覧注意を読み終えてから足す。先に足すと、上限に合わせて縮めずに送り始め、既定の閲覧注意も付かないため。
    /// ペーストが読み終えるまで受け付けない（`ComposeModel.canPasteMedia`）のと同じく、読めなかったら足さない。
    /// 共有されたメディアと、画面にドロップしたメディアに使う。
    /// - Parameter unattachable: 足せなかったときに出す断り。
    private func attachSharedMedia(_ media: [PastedMedia], unattachable: @escaping @MainActor (ComposeModel<UIImage>) -> RefusalText) {
        composer.beginEditing()
        let loadingDefaults = composeDefaultsTask
        tasks.run(.action) { [weak self] in
            await loadingDefaults?.value
            guard let self else { return }
            guard composer.model.canPasteMedia else {
                discardSharedMedia(media)
                logger.error("shared media dropped posting=\(self.composer.model.isPosting, privacy: .public)")
                presentRefusal(unattachable(composer.model))
                return
            }
            composer.model.addPastedMedia(media)
        }
    }

    private func discardSharedMedia(_ media: [PastedMedia]) {
        for item in media {
            item.discard()
        }
    }

    /// acctでアカウントを探して、ホームのタブにプロフィールを開く。ホームを選んでいなければ、探し始める前にホームに切り替える。
    /// 探し終えてから切り替えると、待つ間にほかのタブへ移った人を、ホームへ戻してしまうため。
    private func openProfile(acct: String) {
        // ホームを無効にしていれば、今見ているタブに開く。
        if tabs.placement.location(of: .home) != .disabled {
            tabs.show(.home)
        }
        guard let root = tabs.selectedNavigation?.viewControllers.first else { return }
        let client = client
        let accounts = accounts
        let logger = logger
        openProfile(from: root) {
            guard let account = try await accounts.resolve(.acct(acct), search: { try await client.resolveAccount(acct) }) else {
                logger.error("profile not found acct=\(acct, privacy: .private(mask: .hash))")
                throw ProfileNotFound(acct: acct)
            }
            return account
        }
    }

    /// 外から頼まれた画面を開く。アプリのURL（`scia://`）と、これから足すショートカットは、ここを通す。
    func open(_ destination: AppDestination) {
        // 重ねた画面のどれかを閉じている途中に届くと、閉じていく画面を手前にあるものとして扱い、重ねたり積んだりできずに何もしないことがある。
        // 手前の画面を閉じている途中にその下の画面を閉じ始めると、下の画面が閉じられずに残る。閉じ終えてから行う。
        var screen = rootViewController.presentedViewController
        while let current = screen, !current.isBeingDismissed {
            screen = current.presentedViewController
        }
        if let dismissing = screen, let coordinator = dismissing.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.open(destination) }
            return
        }
        // タブを見せる行き先は、上に重ねた画面を、書きかけのある画面やアプリ内のSafariも含めてすべて閉じてから開く。重ねたままでは見えず、積むのもやめるため。
        // 送られた行き先は使う人の新しい操作なので、出ていた画面より優先する。並びにないか無効にしているタブは開かないので、閉じずにやめる。
        if destination.showsTab, rootViewController.presentedViewController != nil {
            guard canShowTab(of: destination) else {
                logger.error("open tab: no enabled tab in layout")
                return
            }
            rootViewController.closeAllScreens { [weak self] in self?.show(destination) }
            return
        }
        show(destination)
    }

    /// タブを選ぶ行き先（`.tab`、`.userTab`）なら、そのタブが並びにあって有効か。ほかの行き先はtrue。
    private func canShowTab(of destination: AppDestination) -> Bool {
        let item: TabItem?
        switch destination {
        case .tab(let tab): item = tab
        case .userTab(let tab): item = layoutItem(for: tab)
        default: return true
        }
        guard let item else { return false }
        return tabs.placement.location(of: item) != .disabled
    }

    /// 足したタブの行き先に合う、並びの項目。
    private func layoutItem(for tab: AppDestination.UserTab) -> TabItem? {
        for case .item(let item, _) in AppDependencies.settings.tabLayout(for: credential.handle).elements where tab.matches(item, credential: credential) {
            return item
        }
        return nil
    }

    /// 行き先の画面を開く。タブを見せる行き先は、上に重ねた画面を閉じたあとに呼ぶ。
    private func show(_ destination: AppDestination) {
        switch destination {
        case .tab(let item):
            tabs.show(item)
        case .userTab(let tab):
            guard let item = layoutItem(for: tab) else {
                logger.error("open tab: no matching tab in layout")
                return
            }
            tabs.show(item)
        case .settings(let page):
            presentSettings(opening: page)
        case .appearanceGroup(let id):
            presentSettings(opening: .appearance, appearanceGroup: id)
        case .profile(let acct):
            openProfile(acct: acct)
        case .myProfile:
            if let source = tabs.selectedNavigation?.topViewController {
                openMyProfile(from: source)
            }
        case .profileEdit:
            presentProfileEditor()
        case .thread(let statusID):
            guard let source = tabs.selectedNavigation?.topViewController else { return }
            // 押した行の代わりに、画面の安全領域の上端に置いて開く。
            openThread(statusID: statusID, rowFrame: source.view.convert(source.view.safeAreaLayoutGuide.layoutFrame, to: nil), from: source)
        case .editHistory(let statusID):
            let client = client
            push("edit history", { try await client.status(statusID) }) { [weak self] status, source in
                self?.openEditHistory(of: status, filterTitles: [], from: source)
            }
        case .apiResponse(let statusID):
            openAPIResponse(statusID: statusID, from: tabs.selectedNavigation?.topViewController)
        case .accounts(let list):
            guard let source = tabs.selectedNavigation?.topViewController else { return }
            switch list {
            case .followers(let accountID):
                openAccountList(.followers(accountID: accountID ?? credential.accountID), ownerAcct: accountID == nil ? credential.username : nil, from: source)
            case .following(let accountID):
                openAccountList(.following(accountID: accountID ?? credential.accountID), ownerAcct: accountID == nil ? credential.username : nil, from: source)
            case .favourited(let statusID):
                openAccountList(.favouritedBy(statusID), from: source)
            case .reblogged(let statusID):
                openAccountList(.rebloggedBy(statusID), from: source)
            }
        case .hashtag(let name):
            if let source = tabs.selectedNavigation?.topViewController {
                openFeed(.hashtag(name: name), from: source)
            }
        case .accountHashtag(let acct, let name):
            push("account hashtag", resolvingAccount(acct)) { [weak self] account, source in
                self?.openAccountHashtag(name, of: account, from: source)
            }
        case .search(let query):
            showSearch(query: query)
        case .scheduled:
            showScheduledStatuses()
        case .operationStatus:
            showOperationStatus()
        case .notificationRequests:
            openNotificationRequestsInTab()
        case .notificationRequest(let id):
            guard let (controller, viewController) = openNotificationRequestsInTab() else { return }
            let client = client
            tasks.run(.action) { [weak self, weak controller, weak viewController] in
                do {
                    let request = try await client.notificationRequest(id)
                    guard let self, let controller, let viewController else { return }
                    openAccountNotifications(of: request, in: controller.model, from: viewController)
                } catch {
                    self?.logger.error("open notification request failed: \(SciaLog.describe(error), privacy: .public)")
                }
            }
        case .notificationPolicy:
            showNotificationPolicy()
        case .announcements:
            showAnnouncements()
        case .inAppBrowserHeight(let page):
            showInAppBrowserHeight(returningTo: page)
        case .note(let acct):
            let client = client
            let resolve = resolvingAccount(acct)
            lookUp("note", {
                let account = try await resolve()
                guard let relationship = try await client.relationship(with: account.id) else { throw ProfileNotFound(acct: acct) }
                return UserRelation(accountID: account.id, acct: account.acct, relationship: relationship)
            }) { [weak self] relation in
                self?.presentNoteEditor(for: relation)
            }
        case .report(let acct):
            lookUp("report", resolvingAccount(acct)) { [weak self] account in
                self?.presentReport(accountID: account.id, acct: account.acct, statusID: nil)
            }
        case .compose(let screen):
            composer.present(screen)
        }
    }

    /// `acct`の人を探す処理。見つからなければ失敗にする。
    private func resolvingAccount(_ acct: String) -> @Sendable () async throws -> Account {
        let client = client
        let accounts = accounts
        return {
            guard let account = try await accounts.resolve(.acct(acct), search: { try await client.resolveAccount(acct) }) else { throw ProfileNotFound(acct: acct) }
            return account
        }
    }

    /// 開く画面に要るものを読んでから、`open`で開く。読めなければ、ふだんの失敗と同じく知らせる。読む間に次の画面を頼まれたら、前のものは開かない。
    private func lookUp<Value: Sendable>(_ operation: String, _ load: @escaping @Sendable () async throws -> Value, isStillWanted: @escaping @MainActor () -> Bool = { true }, open: @escaping @MainActor (Value) -> Void) {
        destinationOpening.start(.action, load, isStillWanted: isStillWanted) { [weak self] result in
            switch result {
            case .success(let value):
                open(value)
            case .failure(let error):
                self?.logger.error("open \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
                self?.handle(error, title: "開けませんでした")
            }
        }
    }

    /// 選んでいるタブに積む画面に要るものを読んでから、`open`で積む。読む間にタブを移ったり別の画面を開いたりしたら、積まない。スレッドを開く操作と同じ。
    private func push<Value: Sendable>(_ operation: String, _ load: @escaping @Sendable () async throws -> Value, open: @escaping @MainActor (Value, UIViewController) -> Void) {
        guard let source = tabs.selectedNavigation?.topViewController else { return }
        let anchor = PushAnchor(source)
        lookUp(operation, load, isStillWanted: { anchor.isStillShowing }) { [weak source] value in
            guard let source else { return }
            open(value, source)
        }
    }

    #if DEBUG
    /// 確かめるための処理中のチップを、進み具合を少しずつ進めながら`duration`のあいだ出し、済んだら消す。出している途中に呼び直したら、初めから数え直す。
    private func showDebugProgress(for duration: Duration, title: String) {
        debugProgressTask?.cancel()
        let elapsed = stopwatch(on: clock)
        let clock = clock
        // 出し直すたびに別のアプリ内通知にする。しまったあとに出し直しても、出てくるようにするため。
        let id = "debug.progress.\(UUID().uuidString)"
        debugProgressTask = tasks.run(.action) { [weak self] in
            while !Task.isCancelled {
                let fraction = min(elapsed() / duration, 1)
                self?.notices.setPersistent({ _ in
                    Notice(id: id, kind: .progress, title: title, value: Notice.percentText(of: fraction), valueIsProgress: true)
                }, in: .debug)
                guard fraction < 1 else { break }
                try? await clock.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return }
            self?.notices.setPersistent(nil, in: .debug)
        }
    }

    /// Documents/DebugInjectの`file`をAPIの応答と同じ形のJSONとして読み、`tab`の一覧に新着として流す。読めなければ流さずにログに残す。
    private func replyForDebug(to file: String) {
        let url = URL.documentsDirectory.appending(path: "DebugInject").appending(fileName: SafeFileName(file))
        do {
            guard let status = try MastodonDecoder.make().decode([Status].self, from: Data(contentsOf: url)).first else { return }
            composer.reply(to: status)
        } catch {
            // デバッグ版だけで読むファイルなので、`inject`と同じく失敗を丸ごと残す。
            // scialint:disable:next log_private_value
            logger.error("debug reply failed file=\(file, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func inject(_ file: String, into tab: DebugURL.Tab) {
        let url = URL.documentsDirectory.appending(path: "DebugInject").appending(fileName: SafeFileName(file))
        do {
            let data = try Data(contentsOf: url)
            let decoder = MastodonDecoder.make()
            switch tab {
            case .home: home.inject(try decoder.decode([Status].self, from: data))
            case .local: local.inject(try decoder.decode([Status].self, from: data))
            case .federated: federated.inject(try decoder.decode([Status].self, from: data))
            case .notifications: notifications.inject(try decoder.decode([MastodonNotification].self, from: data))
            case .announcements:
                for announcement in try decoder.decode([Announcement].self, from: data) {
                    announcements.apply(.announcement(announcement))
                }
            case .bookmarks, .favourites, .scheduled:
                // ストリームのない一覧なので、新着と同じ経路がない。
                logger.error("debug inject unsupported tab=\(tab.rawValue, privacy: .public)")
            }
        } catch {
            // デバッグ版だけで流すファイルで、どこが読めなかったかを直すため、ログの決まり（docs/logging.md）から外して失敗を丸ごと残す。
            // scialint:disable:next log_private_value
            logger.error("debug inject failed file=\(file, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func handle(_ url: DebugURL) {
        // `scia-debug://reset`の直後に送ったURLは、閉じている途中の画面を手前にあるものとして扱い、重ねたり積んだりできずに何もしないことがある。閉じ終えてから行う。
        if let dismissing = rootViewController.presentedViewController, dismissing.isBeingDismissed, let coordinator = dismissing.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.handle(url) }
            return
        }
        switch url {
        case .dummy(let post):
            home.streamDummy(post)
        case .dummySession:
            // SceneDelegateが、セッションの有無にかかわらず先に受けてダミーのセッションを開くため、ここには来ない。
            break
        case .scenario(let event):
            if let action = ScenarioMode.server?.script.actions[event] {
                handle(action)
            } else {
                ScenarioMode.handle(event)
            }
        case .unauthorized:
            DebugFaults.rejectAsUnauthorized()
            reportUnauthorized()
        case .unreadable:
            DebugFaults.corruptListElements()
            feeds.forEach { $0.reloadIfStarted() }
            savedLists.forEach { $0.reloadIfStarted() }
            notifications.start(purpose: .action)
        case .status(let statusCode, let retryAfter, let target):
            DebugFaults.fail(withStatus: statusCode, retryAfter: retryAfter, target: target)
            feeds.forEach { $0.reloadIfStarted() }
            savedLists.forEach { $0.reloadIfStarted() }
            notifications.start(purpose: .action)
        case .statusCleared:
            DebugFaults.fail(withStatus: nil)
        case .unsupported(let feature):
            DebugFaults.makeUnsupported(feature)
            feeds.forEach { $0.reloadIfStarted() }
            savedLists.forEach { $0.reloadIfStarted() }
            notifications.start(purpose: .action)
        case .regenerating(let isOn):
            DebugFaults.setRegeneratingHome(isOn)
        case .streaming(let isOnline):
            DebugFaults.setStreamingOnline(isOnline)
        case .slowDownload(let seconds):
            DebugFaults.slowDownloads(by: seconds.map { .seconds($0) })
        case .slowMenuIcons(let seconds):
            DebugFaults.slowMenuIcons(by: seconds.map { .seconds($0) })
        case .slowLookups(let seconds):
            DebugFaults.slowLookups(by: seconds.map { .seconds($0) })
        case .slowUploads(let seconds):
            DebugFaults.slowUploads(by: seconds.map { .seconds($0) })
        case .progressNotice(let seconds, let title):
            showDebugProgress(for: .seconds(seconds), title: title ?? "確かめるための処理中")
        case .transientNotice(let title, let seconds):
            notices.showTransient(
                Notice(id: "debug.transient", kind: .info, title: title),
                duration: seconds ?? AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration)
            )
        case .mediaLimits(let limits):
            DebugFaults.overrideMediaLimits(limits)
        case .catalog(let component):
            topViewController.presentComponentCatalog(opening: component)
        case .dump:
            AgentScreenDump.write(scene: rootViewController.view.window?.windowScene)
        case .storageProbe:
            StorageProbe.write()
        case .browser(let url):
            browser.open(url, from: rootViewController.frontmostPresented)
        case .reset:
            rootViewController.dismissPresentedScreens(animated: false)
            for navigation in tabs.allNavigations {
                navigation.popToRootViewController(animated: false)
            }
            tabs.tabBarController.selectedIndex = 0
        case .tuning:
            rootViewController.frontmostPresented.presentTuningPanel()
        case .profileEdit(let note, let field, let crop):
            presentProfileEditor(debugNote: note, debugField: field, debugCrop: crop)
        case .discomfortReport:
            if let window = rootViewController.view.window {
                DiscomfortReportPresenter.present(in: window)
            }
        case .sheetKeyboard:
            // 書いている途中のキーボードから開いたときの動きも見るため、投稿欄は閉じない。高さはメディアを選ぶシートの決めた高さと同じにする。
            SheetKeyboardExperiment.present(from: rootViewController.frontmostPresented, lowHeight: AppDependencies.tuning.value(of: TuningCatalog.composePickerHeight) - (rootViewController.view.window?.safeAreaInsets.bottom ?? 0))
        case .viewer(let index):
            openTopmostMedia(at: index)
        case .autoScroll(let distance, let speed):
            autoScroll(distance: distance, speed: speed)
        case .createList(let title):
            changeTabSourcesForDebug("create") { _ = try await $0.createList(title: title) }
        case .deleteList(let id):
            changeTabSourcesForDebug("delete") { try await $0.deleteList(id) }
        case .followTag(let name):
            changeTabSourcesForDebug("follow tag") { try await $0.followTag(name) }
        case .unfollowTag(let name):
            changeTabSourcesForDebug("unfollow tag") { try await $0.unfollowTag(name) }
        case .statusBarTickerLoop(let isOn):
            statusBarTicker.setLooping(isOn, items: DummyNotifications.samples)
        case .inject(let tab, let file):
            inject(file, into: tab)
        case .compose(let text, let mediaCount, let pollOptions):
            composer.beginEditing()
            if let text {
                composer.replaceTextForDebug(text)
            }
            if let pollOptions {
                composer.replacePollForDebug(pollOptions)
            }
            if let draftImages = ScenarioMode.server?.script.draftImages {
                composer.model.addPastedMedia(DummyMedia.pastedImages(Array(draftImages().prefix(mediaCount))))
            } else {
                composer.model.addPastedMedia(DummyMedia.pastedImages(count: mediaCount))
            }
        case .composeClose:
            composer.endEditing()
        case .composeOpen:
            composer.beginEditing()
        case .composeReply(let file):
            replyForDebug(to: file)
        case .holdArrivals(let isOn):
            DebugFaults.setHoldingArrivals(isOn)
            if !isOn {
                for feed in feeds {
                    feed.releaseHeldArrivals()
                }
                notifications.releaseHeldArrivals()
            }
        }
    }

    /// `scia-debug://lists/...`と`scia-debug://tags/...`で、サーバーのリストやハッシュタグのフォローを変えてから読み直し、タブの並びに反映する。
    private func changeTabSourcesForDebug(_ operation: String, _ change: @escaping @Sendable (MastodonClient) async throws -> Void) {
        let client = client
        tasks.run(.action) { [weak self] in
            do {
                try await change(client)
                self?.logger.info("debug \(operation, privacy: .public) done")
                self?.loadTabSources()
            } catch {
                self?.logger.error("debug \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
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

    /// 選んでいるタブの一覧を、一定の速さで動かす。端に着いたら止める。
    /// タブの中には隠れたままの一覧もあるので、中身のいちばん長いコレクションビューを一覧とみなす。
    /// 動かしている間の落ちたフレームを指のスクロールと同じ仕組みで数え、Documents/DebugAutoscroll.logに1行ずつ書き足す。
    /// 指で操作できない実機ではログを読めないので、`devicectl device copy from`でファイルを取り出して読む。
    private func autoScroll(distance: CGFloat, speed: CGFloat) {
        guard let view = (rootViewController as? UITabBarController)?.selectedViewController?.view,
              let list = Self.collectionViews(in: view).max(by: { $0.contentSize.height < $1.contentSize.height })
        else {
            logger.error("debug autoscroll: no list")
            return
        }
        debugScrollTicker?.stop()
        _ = debugScrollHitches.stop()
        debugScrollHitches.start()
        let startedAt = AppDependencies.mediaTime()
        let settings = AppDependencies.settings
        let label = "\(settings.appearance.mediaArrangement.rawValue) tilts=\(settings.appearance.tiltsStackedPhotos)"
        var remaining = abs(distance)
        let direction: CGFloat = distance < 0 ? -1 : 1
        let ticker = FrameTicker(source: DisplayLinkFrameSource.shared, longestElapsed: nil) { [weak list, weak self] elapsed in
            // 画面を閉じたり、タブを切り替えたりして一覧が画面から外れたら、動かすのも数えるのもやめる。記録は残さない。
            // 選ばれていないタブの一覧はウィンドウから外れるので、ウィンドウにあるかで両方を見分ける。
            guard let list, list.window != nil else {
                _ = self?.debugScrollHitches.stop()
                return false
            }
            let step = min(speed * CGFloat(elapsed), remaining)
            remaining -= step
            let inset = list.adjustedContentInset
            let top = -inset.top
            let bottom = max(list.contentSize.height + inset.bottom - list.bounds.height, top)
            let target = min(max(list.contentOffset.y + step * direction, top), bottom)
            list.contentOffset.y = target
            let reachedEnd = direction > 0 ? target >= bottom : target <= top
            let continues = remaining > 0 && !reachedEnd
            if !continues {
                self?.finishAutoScroll(label: label, distance: distance, duration: AppDependencies.mediaTime() - startedAt)
            }
            return continues
        }
        debugScrollTicker = ticker
        ticker.start()
    }

    private func finishAutoScroll(label: String, distance: CGFloat, duration: CFTimeInterval) {
        let hitches = debugScrollHitches.stop()
        let line = String(format: "%@ distance=%.0f duration=%.2f dropped=%d hitch=%.3f\n", label, distance, duration, hitches.droppedFrames, hitches.hitchTime)
        logger.info("debug autoscroll: \(line, privacy: .public)")
        let file = URL.documentsDirectory.appending(path: "DebugAutoscroll.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    private static func collectionViews(in view: UIView) -> [UICollectionView] {
        guard !view.isHidden else { return [] }
        if let list = view as? UICollectionView { return [list] }
        return view.subviews.flatMap(collectionViews(in:))
    }

    private static func mediaGrids(in view: UIView) -> [MediaGridView] {
        guard !view.isHidden else { return [] }
        if let grid = view as? MediaGridView { return [grid] }
        return view.subviews.flatMap(mediaGrids(in:))
    }
    #endif

    func enterForeground() {
        for feed in feeds {
            feed.enterForeground()
        }
        notifications.enterForeground()
        if hasStarted {
            notificationPolicy.reload(purpose: .display)
        }
        for list in savedLists {
            list.enterForeground()
        }
        scheduled.enterForeground()
        presentedScheduled?.enterForeground()
        announcements.enterForeground()
        threads.enterForeground()
        profileTabs.enterForeground()
        // ほかの端末で作ったり消したりしたリストや、フォローしたハッシュタグを、戻ったときに並びへ反映する。
        if hasStarted {
            loadTabSources()
        }
    }

    func enterBackground() {
        statusBarTicker.clear()
        for feed in feeds {
            feed.enterBackground()
        }
        notifications.enterBackground()
        announcements.enterBackground()
        threads.enterBackground()
        profileTabs.enterBackground()
    }
}

private struct ProfileNotFound: LocalizedError {
    let acct: String

    var errorDescription: String? { "@\(acct)が見つかりませんでした。" }
}

/// リンクのメニューの「プロフィールとして開く」で、リンク先がプロフィールとして見つからなかった。プロフィールでないページのリンクでも起きる。
private struct LinkProfileNotFound: LocalizedError {
    var errorDescription: String? { "リンク先のプロフィールが見つかりませんでした。" }
}

/// リストとハッシュタグのタイムラインの一覧と、そのナビゲーション。使う人ごとに数が違うため、タブの並びに出たときに作る。
@MainActor
private final class ServerFeedRegistry {
    private let make: (TabItem) -> FeedTimelineController?
    private var entries: [TabItem: (controller: FeedTimelineController, navigation: ContentNavigationController)] = [:]
    /// 作ったとき。設定するまでに作ったものは、設定したときにまとめて渡す。セッションを作り終える前に、タブを組むときに作るため。
    var onCreate: ((TabItem, FeedTimelineController, ContentNavigationController) -> Void)? {
        didSet {
            for (item, entry) in entries {
                onCreate?(item, entry.controller, entry.navigation)
            }
        }
    }

    init(make: @escaping (TabItem) -> FeedTimelineController?) {
        self.make = make
    }

    var controllers: [FeedTimelineController] { entries.values.map(\.controller) }

    /// 作ってある項目の一覧。まだ作っていなければnil。
    func controller(for item: TabItem) -> FeedTimelineController? {
        entries[item]?.controller
    }

    /// 項目のナビゲーション。まだなければ作る。リストやハッシュタグでなければnil。
    func navigation(for item: TabItem) -> ContentNavigationController? {
        if let entry = entries[item] { return entry.navigation }
        guard let controller = make(item) else { return nil }
        let navigation = ContentNavigationController(rootViewController: controller.viewController)
        entries[item] = (controller, navigation)
        onCreate?(item, controller, navigation)
        return navigation
    }

    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        for controller in controllers {
            controller.updateStatus(id, transform)
        }
    }

    /// `belongs`に当てはまる項目のうち、`items`にないもの（サーバーにもうないリスト、フォローをやめたハッシュタグ）の一覧を止めて捨て、捨てた項目を返す。
    @discardableResult
    func removeAll(where belongs: (TabItem) -> Bool, except items: Set<TabItem>) -> [TabItem] {
        var removed: [TabItem] = []
        for (item, entry) in entries where belongs(item) && !items.contains(item) {
            entry.controller.stop()
            entries[item] = nil
            removed.append(item)
        }
        return removed
    }
}

/// タブに置いたプロフィール。項目ごとに、アカウントを読むまでの画面から始めるナビゲーションを持つ。
/// 読めたら、セッションがプロフィール画面に差し替え、`setController`で渡す。プロフィール画面は、ナビゲーションの一番下の画面が生かしている。
@MainActor
private final class ProfileTabRegistry {
    private struct Entry {
        let navigation: ContentNavigationController
        /// アカウントを読む画面。プロフィール画面に差し替えたあとも、アイコンを読み直すのに使う。
        let loading: ProfileTabLoadingViewController
        /// この項目で始めた処理の持ち主。外したときに閉じ、読み込みと新着の読み直しを止める。
        let tasks: TaskScope
        weak var controller: ProfileController?
    }

    private let make: (TabItem) -> (ProfileTabLoadingViewController, TaskScope)?
    private var entries: [TabItem: Entry] = [:]
    /// 作ったとき。設定するまでに作ったものは、設定したときにまとめて渡す。セッションを作り終える前に、タブを組むときに作るため。
    var onCreate: ((TabItem, ProfileTabLoadingViewController, ContentNavigationController) -> Void)? {
        didSet {
            for (item, entry) in entries {
                onCreate?(item, entry.loading, entry.navigation)
            }
        }
    }

    init(make: @escaping (TabItem) -> (ProfileTabLoadingViewController, TaskScope)?) {
        self.make = make
    }

    /// 項目のナビゲーション。まだなければ作る。プロフィールでなければnil。
    func navigation(for item: TabItem) -> ContentNavigationController? {
        if let entry = entries[item] { return entry.navigation }
        guard let (loading, tasks) = make(item) else { return nil }
        let navigation = ContentNavigationController(rootViewController: loading)
        entries[item] = Entry(navigation: navigation, loading: loading, tasks: tasks)
        onCreate?(item, loading, navigation)
        return navigation
    }

    func tasks(for item: TabItem) -> TaskScope? {
        entries[item]?.tasks
    }

    func loading(for item: TabItem) -> ProfileTabLoadingViewController? {
        entries[item]?.loading
    }

    /// アカウントを読めて作ったプロフィール画面を渡す。読んでいる間にバックグラウンドへ入っていたら、そのことを伝える。
    func setController(_ controller: ProfileController, for item: TabItem) {
        entries[item]?.controller = controller
        if !isInForeground {
            controller.enterBackground()
        }
    }

    /// アカウントを読んでいる間に変わっても、作ったプロフィール画面に伝えられるよう覚えておく。
    private var isInForeground = true

    func enterForeground() {
        isInForeground = true
        for entry in entries.values {
            entry.controller?.enterForeground()
        }
    }

    func enterBackground() {
        isInForeground = false
        for entry in entries.values {
            entry.controller?.enterBackground()
        }
    }

    /// `items`にない項目（「タブから外す」で外したもの）の処理を止めて捨て、捨てた項目を返す。
    @discardableResult
    func removeAll(except items: Set<TabItem>) -> [TabItem] {
        var removed: [TabItem] = []
        for (item, entry) in entries where !items.contains(item) {
            entry.tasks.close()
            entries[item] = nil
            removed.append(item)
        }
        return removed
    }
}

/// 開いた一覧に積んだハッシュタグの一覧を弱く持つ。一覧は、積んだ画面が生かしている。
@MainActor
private final class PushedFeedRegistry {
    private struct Entry {
        weak var controller: FeedTimelineController?
    }

    private var entries: [Entry] = []

    func add(_ controller: FeedTimelineController) {
        entries.removeAll { $0.controller == nil }
        entries.append(Entry(controller: controller))
    }

    var controllers: [FeedTimelineController] {
        entries.removeAll { $0.controller == nil }
        return entries.compactMap(\.controller)
    }

    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        for controller in controllers {
            controller.updateStatus(id, transform)
        }
    }
}

/// 開いているスレッドの画面を弱く持つ。
/// 開いている検索の結果。投稿への操作の結果を、開いているものすべてに反映する。閉じたものは自然に消える。
@MainActor
private final class SearchRegistry {
    private struct Entry {
        weak var model: SearchModel?
    }

    private var entries: [Entry] = []

    func add(_ model: SearchModel) {
        entries.removeAll { $0.model == nil }
        entries.append(Entry(model: model))
    }

    private var models: [SearchModel] {
        entries.removeAll { $0.model == nil }
        return entries.compactMap(\.model)
    }

    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        for model in models {
            model.updateStatus(id, transform)
        }
    }

    func removeStatus(_ id: Status.ID) {
        for model in models {
            model.removeStatus(id)
        }
    }

    func excludeAccount(_ id: String) {
        for model in models {
            model.excludeAccount(id)
        }
    }
}

@MainActor
private final class ThreadRegistry {
    private struct Entry {
        weak var controller: ThreadController?
    }

    private var entries: [Entry] = []

    func add(_ controller: ThreadController) {
        entries.removeAll { $0.controller == nil }
        entries.append(Entry(controller: controller))
    }

    private var controllers: [ThreadController] {
        entries.removeAll { $0.controller == nil }
        return entries.compactMap(\.controller)
    }

    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        for controller in controllers {
            controller.updateStatus(id, transform)
        }
    }

    func removeStatus(_ id: Status.ID) {
        for controller in controllers {
            controller.removeStatus(id)
        }
    }

    func receivePosted(_ status: Status) {
        for controller in controllers {
            controller.receivePosted(status)
        }
    }

    func enterForeground() {
        for controller in controllers {
            controller.enterForeground()
        }
    }

    func enterBackground() {
        for controller in controllers {
            controller.enterBackground()
        }
    }
}

/// 初期化の途中で作る処理から、初期化を終えたセッションを呼ぶための入れ物。
@MainActor
private final class SessionReference {
    weak var session: SessionController?
}

/// 開いているプロフィール画面を弱く持つ。
@MainActor
private final class ProfileRegistry {
    private struct Entry {
        weak var controller: ProfileController?
    }

    private var entries: [Entry] = []
    /// 読んだ関係のキャッシュ。開き直したプロフィールで前に読んだ関係から始め、ユーザーのメニューの関係の項目をその場で組むのに使う。
    let relationships: RelationshipCache

    init(relationships: RelationshipCache) {
        self.relationships = relationships
    }

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

    /// ユーザーのメニューで変えた関係を、開いている相手のプロフィールに反映して覚える。
    /// - Parameter reloadsAccount: フォローを変えた。フォローのAPIは関係だけを返し、フォロワー数は古いままなので、アカウントを読み直す。
    func apply(_ relationship: Relationship, reloadsAccount: Bool) {
        relationships[relationship.id] = relationship
        entries.removeAll { $0.controller == nil }
        for entry in entries where entry.controller?.accountID == relationship.id {
            entry.controller?.apply(relationship, reloadsAccount: reloadsAccount)
        }
    }

    /// 編集して保存した自分のプロフィールを、開いている自分のプロフィールに反映する。
    func apply(edited account: Account) {
        entries.removeAll { $0.controller == nil }
        for entry in entries where entry.controller?.accountID == account.id {
            entry.controller?.apply(edited: account)
        }
    }

    /// `accountID`のプロフィールを開いていれば、固定された投稿を読み直す。
    func reloadPinned(of accountID: String) {
        entries.removeAll { $0.controller == nil }
        for entry in entries where entry.controller?.accountID == accountID {
            entry.controller?.reloadPinned()
        }
    }

    /// `accountID`のプロフィールを開いていれば、注目のハッシュタグと紹介しているユーザーを読み直す。
    func reloadFeatured(of accountID: String) {
        entries.removeAll { $0.controller == nil }
        for entry in entries where entry.controller?.accountID == accountID {
            entry.controller?.reloadFeatured()
        }
    }
}

/// 選んでいるタブをもう一度押したとき、奥の画面を開いていれば標準どおり最初の画面へ戻し、最初の画面にいれば最上部へ動かす。
/// タブを切り替えたら、`didSelect`で知らせる。
@MainActor
final class TabReselectionDelegate: NSObject, UITabBarControllerDelegate {
    private let scrollToTop: (UINavigationController) -> Void
    /// タブで前に出ているナビゲーション。切り替えタブなら、開いている項目のもの。
    private let navigation: (UITab) -> UINavigationController?
    private let didSelect: (UITabBarController) -> Void
    /// 別のタブを選び終えたとき。ステータスバーの通知を流してよいかを見直す。
    var onSelect: (() -> Void)?

    init(scrollToTop: @escaping (UINavigationController) -> Void, navigation: @escaping (UITab) -> UINavigationController?, didSelect: @escaping (UITabBarController) -> Void) {
        self.scrollToTop = scrollToTop
        self.navigation = navigation
        self.didSelect = didSelect
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
        guard selectedTab != previousTab else { return }
        didSelect(tabBarController)
        onSelect?()
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab == tabBarController.selectedTab else {
            UserAction.selectTab(Self.logName(of: tab)).record()
            return true
        }
        guard let navigation = navigation(tab) else {
            UserAction.reselectTab(Self.logName(of: tab)).record()
            return true
        }
        guard navigation.viewControllers.count == 1 else {
            // タブの中身はナビゲーションを入れ物に入れているので、UIKitは最初の画面へ戻さない（TabContainerViewController）。標準と同じく動きを付けて戻す。
            navigation.popToRootViewController(animated: true)
            UserAction.reselectTab(Self.logName(of: tab)).record()
            return false
        }
        // 慣性で動いている途中なら、最上部へ動かす時点でそれまでのスクロールが記録される。一覧で押した操作がその後に並ぶよう、後で記録する。
        scrollToTop(navigation)
        UserAction.reselectTab(Self.logName(of: tab)).record()
        return false
    }

    /// 操作の記録に残すタブの名前。タブの識別子は並びに保存する値で、リストやハッシュタグの名前を含むため、そのまま残さない。
    /// 切り替えタブのように並びの項目でないタブは、識別子をそのまま残す。
    private static func logName(of tab: UITab) -> String {
        TabItem(rawValue: tab.identifier)?.logName ?? tab.identifier
    }
}

// MARK: - リストの編集

extension SessionController: ListEditorHost {
    var listPresenter: UIViewController { topViewController }

    func knownList(_ id: String) -> MastodonList? {
        loadedLists?.first { $0.id == id }
    }

    /// 作ったリストは、「タブに追加」と同じく、有効にして切り替えタブの末尾に入れる。リストの一覧を読み直すのは待たない。
    func listDidCreate(_ list: MastodonList) {
        listChangeCount += 1
        loadedLists = (loadedLists ?? []).filter { $0.id != list.id } + [list]
        setTabLayout(AppDependencies.settings.tabLayout(for: credential.handle).adding(.list(id: list.id, title: list.title)))
    }

    /// 変えたリストを覚え、名前が変わっていれば、並びの名前と、タブバーと一覧の見出しの名前をすぐ変える。
    func listDidUpdate(_ list: MastodonList) {
        listChangeCount += 1
        let previous = knownList(list.id)
        loadedLists = loadedLists.map { lists in lists.map { $0.id == list.id ? list : $0 } } ?? [list]
        guard previous?.title != list.title else { return }
        let item = TabItem.list(id: list.id, title: list.title)
        serverFeeds.controller(for: item)?.viewController.title = list.title
        tabs.retitle(item)
        setTabLayout(AppDependencies.settings.tabLayout(for: credential.handle).replacing(item))
    }

    /// 消したリストを、リストの一覧を読み直すのを待たずに並びから外し、一覧を止める。開いていたら、UIKitが選んだ先頭のタブへ移る。
    func listDidDelete(_ id: String) {
        listChangeCount += 1
        loadedLists = loadedLists?.filter { $0.id != id }
        let item = TabItem.list(id: id, title: "")
        setTabLayout(AppDependencies.settings.tabLayout(for: credential.handle).removing(item))
        tabs.forget(serverFeeds.removeAll(where: { $0 == item }, except: []))
    }

    func listFailureReason(for error: any Error) async -> ErrorPresentation {
        await failureReason(for: error)
    }

    func reportListFailure(title: String, reason: ErrorPresentation) {
        operationStatus.recordFailure(title: title, reason: reason)
        showFailureNotice(.interactionFailure(title: title) { [weak self] in
            self?.presentAlert(title: title, message: reason.text)
        })
    }
}
