import os
import SciaCore
import UIKit

/// タイムライン表示。スクロール位置の制御を細かく行うため、UICollectionViewとdiffable data sourceで組む。
final class TimelineViewController: UIViewController, NavigationBarTapPassing {
    private enum Section { case main }
    typealias ItemID = TimelineEntry.ID

    private let logger = SciaLog.logger(category: "timeline")

    /// 一覧ごとに変わる文言。
    typealias Texts = TimelineTexts

    /// 一覧全体の状態。投稿がないときの表示に使う。
    enum ContentState: Equatable {
        case loading
        case loaded
        /// サーバーがホームを再生成中で、まだ投稿が返ってこない。
        case regenerating
        case failed(ErrorPresentation)
    }

    /// 末尾の読み込みの状態。フッターに出す。
    enum FooterState: Equatable {
        case idle
        case loading
        case failed(ErrorPresentation)
        case reachedEnd
    }

    /// 末尾が近づいたときに呼ぶ。古い投稿の読み込みを始める。
    var onApproachingEnd: (() -> Void)?
    /// 失敗表示の再試行ボタンで呼ぶ。
    var onRetry: (() -> Void)?
    /// 画面に表示されている投稿が変わったときに、表示中の投稿のIDを渡して呼ぶ。
    var onVisibleStatusesChange: (([Status.ID]) -> Void)?
    /// 画面に表示されている通知が変わったときに、表示中の通知のIDを渡して呼ぶ。
    var onVisibleNotificationsChange: (([MastodonNotification.ID]) -> Void)?
    /// 画面に表示されている行のうち、サーバーのカードがまだなく、リンク先だけのカードを出している投稿が変わったときに呼ぶ。
    /// ブーストなら、ブーストされた投稿を渡す。画面から消えたら空で呼ぶ。
    var onVisibleLinkOnlyCardsChange: (([Status]) -> Void)?
    /// 投稿への操作が選ばれたときに呼ぶ。ブーストなら、ブーストした投稿を渡す。
    var onStatusAction: ((StatusAction, Status) -> Void)?
    /// フォローリクエストの通知のメニューで、承認か却下が選ばれたときに、その通知を渡して呼ぶ。
    var onFollowRequestDecision: ((FollowRequestDecision, MastodonNotification) -> Void)?
    /// 通知のメニューで、通知の削除が選ばれたときに、その通知を渡して呼ぶ。
    var onDismissNotification: ((MastodonNotification) -> Void)?
    /// まとめた通知の「ほか3人」が押されたときに呼ぶ。通知を送った人の一覧を開く。
    var onOpenGroupAccounts: ((MastodonNotification) -> Void)?
    /// 右上に出す、投稿欄で書き始めるボタンが押されたときに呼ぶ。
    /// アプリ内のSafariのシートの裏に隠れているときや、設定で空の投稿欄を隠しているときに、投稿欄に触れられないため、その入口にする。
    var onFocusInlineCompose: (() -> Void)?
    private lazy var focusInlineComposeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.onFocusInlineCompose?() })
        item.accessibilityLabel = "投稿欄に書く"
        return item
    }()
    private var showsFocusInlineCompose = false
    /// ログイン中のアカウントのID。ブーストできる投稿かの判定に使う。
    var myAccountID: String?
    /// 指によるスクロールが止まったとき、または長押しのメニューが閉じたときに呼ぶ。
    var onInteractionSettle: (() -> Void)?
    /// ギャップがタップされたときに、どちらの端から読むかを添えて呼ぶ。
    var onGapSelect: ((String, TimelineStore.GapDirection) -> Void)?
    /// 読み込み中でないギャップが表示領域に近づいたときに、どちらの端から読むかを添えて呼ぶ。スクロールするたびに呼ぶことがある。
    var onGapApproach: ((String, TimelineStore.GapDirection) -> Void)?
    /// 投稿の行か、投稿を含む通知の行の、中の部品が受けなかった押下で呼ぶ。押した投稿（通知なら通知の投稿）と、行のウインドウ上の枠を渡す。スレッドを開く。nilなら押せない。
    var onOpenThread: ((Status, CGRect) -> Void)?
    /// 引用元の中の引用のように、IDしか分からない投稿のスレッドを開くときに、IDと、押した行のウインドウ上の枠を渡して呼ぶ。
    var onOpenStatusID: ((Status.ID, CGRect) -> Void)?
    /// スレッドの画面で押した投稿。押してもスレッドを開き直さない。
    var threadFocusID: Status.ID?
    /// スレッドを開くときに、押した行を一覧で見えていた位置に置くため、上の余白に足している高さ。
    private var openingInset: CGFloat = 0
    /// 画面に出るときに、この行の上端をウインドウのこの高さに置く。
    private var pendingOpening: (id: ItemID, windowY: CGFloat)?
    /// 投稿のアイコンやブーストした人の行がタップされたとき、または長押しのメニューで選ばれたときに、そのアカウントを渡して呼ぶ。
    var onOpenProfile: ((Account) -> Void)?
    /// アカウントの全体を持たない相手（メンション）のプロフィールを、IDで開く。
    var onOpenProfileID: ((String) -> Void)?
    /// 投稿の本文のリンクがタップされたときに、行き先と、本文を描いた投稿（ブーストなら元の投稿）を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination, Status) -> Void)?
    /// 長押しのメニューの開く項目で、開く場所を決めてURLを開く。
    var onOpenURL: ((URL, LinkBrowser) -> Void)?
    /// リンクのメニューの「プロフィールとして開く」で、リンク先をプロフィールとして探して開く。
    var onOpenProfileURL: ((URL) -> Void)?
    /// ハッシュタグのメニューの「投稿したユーザーの投稿」で、そのユーザーのハッシュタグの付いた投稿を開く。
    var onOpenAccountHashtag: ((String, Account) -> Void)?
    /// 投稿のメニューの「ハッシュタグ」の「すべての投稿」で、ハッシュタグのタイムラインを開く。`#`を除いた名前を渡す。
    var onOpenHashtag: ((String) -> Void)?
    /// ナビゲーションから外された。積んで開いた一覧が、読み込みと購読をやめるのに使う。
    var onRemovedFromParent: (() -> Void)?
    /// 画面に出始めたとき（true）と、見えなくなったとき（false）。前に出ている間だけ新着を読む一覧が使う。
    var onVisibilityChange: ((Bool) -> Void)?
    /// ユーザーのメニューのメンションとハンドルをコピーを組むもの。nilなら2つの項目を出さない。
    var userMenuActions: UserMenuActions?
    /// ハッシュタグのメニューのミュートを組むもの。nilなら項目を出さない。
    var hashtagMuteActions: HashtagMuteActions?
    /// この画面が表示されている間、生かしておくもの。画面を組み立てたコントローラーを、ナビゲーションから外されるまで残すのに使う。
    var lifetimeOwner: AnyObject?
    /// 一覧の頭に置き、一緒にスクロールするビュー。プロフィールのヘッダーに使う。表示より前に設定する。
    /// 置くと、投稿がないときの全面の表示は出さず、読み込みの状態はフッターだけで示す。ヘッダーを覆わないようにするため。
    var headerView: UIView?
    /// 画面に出るたびに呼ぶ。開くまで読まない一覧が、初めて開いたときに読み始めるのに使う。
    var onAppearing: (() -> Void)?
    /// 一覧がスクロールしたときと、安全領域やバーの高さが変わったときに呼ぶ。ヘッダーを置いた画面が、ヘッダーやバーの見た目を位置に合わせるのに使う。
    var onScroll: ((UIScrollView) -> Void)?
    /// ステータスバーの文字の色。ヘッダーを置いた画面が、ステータスバーの下に見えているものに合わせて変える。
    /// ナビゲーションバーのボタンのない場所のタップを、一覧に通す。ヘッダーを置いた画面が、バーの下に入れたヘッダー画像を押せるようにする。
    var passesEmptyNavigationBarTaps = false
    var statusBarStyle: UIStatusBarStyle = .default {
        didSet {
            guard statusBarStyle != oldValue else { return }
            setNeedsStatusBarAppearanceUpdate()
        }
    }
    #if DEBUG
    /// デバッグメニューに出す、このタイムライン用の検証の操作。表示より前に設定する。
    var debugActions: [UIMenuElement] = []
    /// デバッグメニューから起こした障害を、URLで届いたときと同じく処理する。nilなら障害の項目を出さない。表示より前に設定する。
    var onDebugURL: (@MainActor (DebugURL) -> Void)?
    #endif

    /// 末尾から何件手前で古い投稿の読み込みを始めるか。
    private let prefetchThreshold = 10

    private(set) lazy var collectionView: UICollectionView = TimelineCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    private var entries: [ItemID: TimelineEntry] = [:]
    /// 長押しのメニューを開いている間に届いたアイコンを、メニューを組み直さずに差し替える。
    let contextMenuIcons = ContextMenuIconSwapper()
    /// 行を触れた位置。行のタップの処理は押した位置を受け取らないため、タップでメニューを出す位置にする。
    let touchRecorder = TouchLocationRecorder()
    /// 行の長押しにメニュー以外を選んだときに、長押しを受ける。
    var rowLongPress: ObjectLongPress?
    /// 組んでいるメニューで、アイコンを読んでから差し替える人。メニューを組み終えたら、まとめて読み始める。
    var pendingMenuIcons: [PendingMenuIcon] = []
    /// 前回`setEntries`で並べた配列。次に渡された`keepingRowContentsOf`と同じ配列かを、中身を比べずに確かめるために持つ。
    private var appliedEntries: [TimelineEntry] = []
    /// 隣の行とアイコン同士を線でつなぐ行。並びが変わるたびに決め直す。
    private var replyConnections: [ItemID: ReplyConnection] = [:]
    /// すぐ上の行が返信先なら、返信のラベルを出さない。スレッドのように古い順に並べる一覧で、線で返信先が分かるため。
    /// ただし、スレッドで押した投稿（`threadFocusID`）にはラベルを残す。新しい順に並べる一覧では、返信先は下の行になるため使わない。
    var hidesReplyLabelBelowParent = false
    private var loadingGapIDs: Set<String> = []
    /// 直近の読み込みに失敗したギャップと、その理由。行の中で読めなかったことを知らせる。
    private var gapFailures: [String: ErrorPresentation] = [:]
    private var isShowingMenu = false
    /// メニューを出している間に届いた並びの更新。閉じたときに反映する。
    private var heldEntries: HeldEntries?
    /// メニューを出している間に求められた描き直し。
    private var heldReconfigureIDs: Set<ItemID> = []
    private var contentSizeObserver: (any NSObjectProtocol)?
    /// 端末の文字の大きさが変わったときに、組み直す前に覚えた読んでいる位置。
    private var contentSizeAnchor: ScrollAnchor?
    /// 表示中のギャップのID。スクロールのたびに全要素を調べないよう、別に持つ。
    private var gapIDs: [String] = []
    /// 指で最後に動かした向き。ギャップをどちらの端から読むかに使う。
    ///
    /// スクロール位置の増減からは取らない。上へ戻ると、見積もりから実寸へ変わったセルの分をUICollectionViewが位置で補正し、
    /// 位置が逆向きにも動くため。
    private var lastScrollDirection: ScrollDirection?

    private enum ScrollDirection {
        /// 上へ戻っている。新しい投稿の方へ向かっている。
        case towardNewer
        case towardOlder
    }
    private(set) var contentState = ContentState.loaded
    private(set) var footerState = FooterState.idle
    private(set) var unreadCount = 0
    /// スクロール位置を補正している間は、途中の表示を既読として報告しない。
    private var isRestoringAnchor = false
    /// 最上部や投稿へスプリングで動かしている間、毎フレーム経過時間を渡すもの。
    private var springScrollTicker: FrameTicker?
    /// 最上部や投稿へスプリングで動かすときに、毎フレームの経過時間を送る元。テストでは手で送る元に替える。
    var frameSource: any FrameSource = DisplayLinkFrameSource.shared
    /// スプリングで動かしている間の、スプリングの位置の進め方と今の速さ。
    private var springScroll: SpringScroll?
    /// スプリングで動かしている行き先。
    private var springScrollDestination = SpringScrollDestination.top
    /// スプリングで動かしている間だけ有効にし、指が触れた時点で止める。触れたタッチは、指が離れるまで中身に渡さない。
    /// UIKitのスクロールと同じく、動いている一覧に触れて止めたつもりで、指の下の画像やリンクが開かないようにするため。
    private(set) lazy var springScrollInterruption = makeSpringScrollInterruption()
    /// 指で動かしているスクロールの始まり。止まったら違和感レポート用に記録する。
    private var scrollStart: (offset: CGFloat, time: CFTimeInterval)?
    private let scrollHitches = ScrollHitchMonitor()
    /// 投稿のメニューの、システムの翻訳で出す翻訳シート。
    let translation = SystemTranslation()
    /// 「テキストを選択」で選べる状態にしている本文。一覧の行をタップしたときと、画面を離れたときにやめる。
    private weak var textSelectionBody: PostBodyView?
    /// 投稿のメニューで「テキストを選択」を選んだ本文と、その投稿。メニューが閉じ終えてから選び始める。閉じる途中に選ぶと、編集メニューが出ないため。
    private var pendingTextSelection: (body: PostBodyView, statusID: Status.ID)?
    private lazy var newArrivalsButton = makeNewArrivalsButton()
    /// 新着ボタンを出す向きか。消える動きの途中は、`isHidden`がまだ偽でも偽になる。
    private var newArrivalsButtonShown = false
    /// 新着ボタンの出し入れを始めた回数。途中で向きを変えると、前の動きの完了がその場で呼ばれるため、最後の動きの完了でだけ隠す。
    private var newArrivalsButtonGeneration = 0
    /// 一覧の最上部から引っぱって、浮かべた新着のボタンを下げている量。
    private var pulledDistance: CGFloat = 0
    /// アプリ全体のアプリ内通知。お気に入りやブーストの失敗、リンクのコピーを出す。セッションが入れる。
    var notices: NoticeCenter?
    /// 添付ファイルのビューアで、共有や保存のために落とす処理。ビューアを閉じても続けるため、セッションで持つ。
    var mediaTransfers: MediaTransferCenter?
    private var timeRefreshTask: Task<Void, Never>?
    /// 今の日付。テストでは決まった日付に差し替える。
    var now: () -> Date = AppDependencies.now
    /// 画面の描き換えと同じ時間。テストでは差し替える。
    var mediaTime: () -> CFTimeInterval = AppDependencies.mediaTime
    /// 時間をおく処理の時計。テストでは手で進める時計に差し替える。
    var clock: any Clock<Duration> = AppDependencies.clock
    private let texts: Texts
    /// 一覧を一番上から引っぱって離したときに、最新の状態を読む。読み終えるまで更新コントロールを出し続ける。
    /// どの一覧でも同じ操作で読み直せるよう、一覧を持つ側に必ず決めさせる。
    private let refresh: @MainActor () async -> Void
    private let refreshControl = UIRefreshControl()
    private var refreshTask: Task<Void, Never>?
    let tuning: TuningStore
    let emojiImages: EmojiImageStore<UIImage>
    let mediaImages: MediaImageStore<UIImage>
    let avatarImages: AvatarImageStore<UIImage>
    let network: NetworkConditionsMonitor
    let settings: AppSettings
    /// スクロールが止まったときに見えている画像を、ビューアで開く元の画像で先読みする。セッションが入れる。nilなら先読みしない。
    var mediaPrefetcher: MediaPrefetcher?
    /// 添付ファイルをぼかすか。閲覧注意のぼかしを外した投稿と、メニューから隠した投稿を覚える。セッションがほかの画面とそろえる。
    var mediaCovers = MediaCovers()
    /// この画面で開いたり隠したりしたときに、変えたあとの状態と、変えた投稿を渡して呼ぶ。
    var onChangeMediaCovers: ((MediaCovers, Status) -> Void)?
    /// fxtwitterから読んだXの投稿。セッションの中で1つを共有する。
    var xPosts: XPostStore?
    /// この一覧で当てるサーバーのフィルターと、警告で折りたたんだ投稿のうち開いたもの。一覧を持つ側が、一覧の場所に合わせて入れる。
    var filterWarnings = FilterWarnings()
    /// ブロックかミュートしている人の引用元のうち、押して開いたもの。
    var quoteReveals = QuoteReveals()
    /// 引用元の、受け取ったあとの変化。セッションがほかの画面とそろえる。
    var quoteSourceChanges = QuoteSourceChanges()
    /// 投票する前に選んでいる選択肢と、結果を見ると選んだ投票、送っている途中の投票。
    var pollChoices = PollChoices()
    /// 投票の「投票」が押されたときに、選んだ選択肢と、押した投稿（ブーストならブーストした投稿）を渡して呼ぶ。
    /// 送り終えたら、呼ばれた側が`finishVoting(_:succeeded:)`を呼ぶ。
    var onVote: ((Set<Int>, Status) -> Void)?
    /// 投票の「更新」が押されたときに、押した投稿を渡して呼ぶ。読み終えたら、呼ばれた側が`finishRefreshingPoll(_:)`を呼ぶ。
    var onRefreshPoll: ((Status) -> Void)?
    /// 注意書きのある投稿の本文を開いているか。サーバーの設定が読めたら、セッションが既定を入れる。
    var spoilerExpansion = SpoilerExpansion() {
        didSet {
            guard spoilerExpansion.expandsByDefault != oldValue.expandsByDefault, isViewLoaded else { return }
            reconfigure(Set(displayedItemIDs.filter { status(for: $0)?.displayed.spoilerText.isEmpty == false }))
        }
    }

    init(
        texts: Texts = .home,
        refresh: @escaping @MainActor () async -> Void,
        tuning: TuningStore = AppDependencies.tuning,
        emojiImages: EmojiImageStore<UIImage> = AppDependencies.emojiImages,
        mediaImages: MediaImageStore<UIImage> = AppDependencies.mediaImages,
        avatarImages: AvatarImageStore<UIImage> = AppDependencies.avatarImages,
        network: NetworkConditionsMonitor = AppDependencies.network,
        settings: AppSettings = AppDependencies.settings
    ) {
        self.texts = texts
        self.refresh = refresh
        self.tuning = tuning
        self.emojiImages = emojiImages
        self.mediaImages = mediaImages
        self.avatarImages = avatarImages
        self.network = network
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 画面を読み込んだときに並べた右上のボタン。投稿欄で書き始めるボタンは、出すときにこの先頭に足す。
    private var baseBarItems: [UIBarButtonItem] = []
    /// 画面を組み立てる側が足す右上のボタン。投稿欄で書き始めるボタンの左に並ぶ。表示より前に設定する。
    var screenBarItems: [UIBarButtonItem] = []

    /// 右上に投稿欄で書き始めるボタンを出すかを決める。画面を読み込む前は値だけ覚える。
    func setShowsFocusInlineCompose(_ shows: Bool) {
        guard showsFocusInlineCompose != shows else { return }
        showsFocusInlineCompose = shows
        if isViewLoaded { applyBarItems() }
    }

    /// `rightBarButtonItems`は右から並ぶため、先頭に足したボタンがいちばん右に来る。
    private func applyBarItems() {
        navigationItem.rightBarButtonItems = (showsFocusInlineCompose && onFocusInlineCompose != nil ? [focusInlineComposeItem] : []) + screenBarItems + baseBarItems
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 画面を組み立てる側が先に入れたサブタイトル（人の一覧のハンドル）を消さないよう、文言にあるときだけ入れる。
        if let subtitle = texts.subtitle {
            navigationItem.subtitle = subtitle
        }
        if !texts.title.isEmpty {
            title = texts.title
        }
        #if DEBUG
        // 撮影モードでは、宣伝の素材に開発用のボタンを映さない。
        if ScenarioMode.server == nil {
            baseBarItems = [makeDebugMenuButton(screenActions: debugActions, faults: onDebugURL.map { DebugFaultMenu.make(handle: $0) }, handle: onDebugURL)]
        }
        #endif
        applyBarItems()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.hidesTopEdgeEffectOnMac()
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.addGestureRecognizer(springScrollInterruption)
        installRowObjectActions()
        // タブバーの上の投稿欄で書いている間も、読み進めるだけならキーボードを閉じない。キーボードまで引き下ろしたら閉じる。
        collectionView.keyboardDismissMode = .interactive
        refreshControl.addAction(UIAction { [weak self] _ in self?.beginRefresh() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        // 一覧が画面の高さに満たないときも、引っぱって読み直せるようにする。
        collectionView.alwaysBounceVertical = true
        view.addSubview(collectionView)
        // 新着のボタンは、この一覧の部品として画面と一緒に流れる。一番上の投稿の名前や本文を隠さないよう、時刻のある右上に置く。
        // チップの列はウインドウに重ね、このボタンが出ていてもずらさずに上に重ねる。
        view.addSubview(newArrivalsButton)
        NSLayoutConstraint.activate([
            newArrivalsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            newArrivalsButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        AppDependencies.stateDumps.register(texts.dumpName, owner: self) { $0.stateDump() }
        emojiImages.addListener(owner: self) { [weak self] urls in self?.emojiImagesDidLoad(urls) }
        avatarImages.addListener(owner: self) { [weak self] key in self?.avatarImageDidLoad(key) }
        observeTuning()
        // 行の文字は、組むときのアプリの文字の大きさで決めるため、端末の文字の大きさが変わったら組み直す。
        // アプリへの通知は、一覧に特性が伝わる前に届くので、そこで読んでいる位置を覚える。一覧に特性が伝わると、UIKitが画面の外の行の高さを
        // 見積もりに戻して測り直し、読んでいる位置がずれるため、伝わったあとに組み直して、覚えた位置へ戻す。
        contentSizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.contentSizeAnchor == nil, self.viewIfLoaded?.window != nil else { return }
                self.contentSizeAnchor = self.currentAnchor()
                // 戻し終えるまで、測り直しで一時的に見えた投稿を表示中として報告しない。報告すると、読んでいない投稿まで既読になり、戻らない。
                self.isRestoringAnchor = true
            }
        }
        collectionView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UICollectionView, _) in
            self?.contentSizeDidChange()
        }
        translation.install(in: self)
    }

    isolated deinit {
        contentSizeObserver.map(NotificationCenter.default.removeObserver)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    /// 安全領域やナビゲーションバーの高さが変わったら、チップの列を置き直す。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        noticeOverlay?.update()
        onScroll?(collectionView)
    }

    /// 他のタブにいる間に表示が変わっても既読にしないため、画面に出たときに改めて報告する。
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        onAppearing?()
        onVisibilityChange?(true)
        applyPendingOpening()
    }

    /// 読んでいる途中にもう一度引っぱっても、読み込みは重ねず、今の読み込みが終わったところで閉じる。
    private func beginRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            refreshTask = nil
            refreshControl.endRefreshing()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reportVisibleItems()
        startRefreshingTimes()
    }

    /// ハードウェアキーボードのnで、投稿欄で書き始める。入力欄に書いている間は、文字の入力が先に受けるため効かない。
    override var keyCommands: [UIKeyCommand]? {
        guard onFocusInlineCompose != nil else { return super.keyCommands }
        let focus = UIKeyCommand(title: "投稿欄に書く", action: #selector(focusInlineComposeFromKeyboard), input: "n")
        return (super.keyCommands ?? []) + [focus]
    }

    @objc private func focusInlineComposeFromKeyboard() {
        onFocusInlineCompose?()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { onRemovedFromParent?() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        endTextSelection()
        timeRefreshTask?.cancel()
        timeRefreshTask = nil
        onVisibleLinkOnlyCardsChange?([])
        onVisibilityChange?(false)
    }

    /// 相対表記の時刻を、表示中の行だけ1秒ごとに書き直す。行の高さは変わらないため、並びは描き直さない。
    private func startRefreshingTimes() {
        timeRefreshTask?.cancel()
        let clock = clock
        timeRefreshTask = Task { [weak self] in
            while (try? await clock.sleep(for: .seconds(1), tolerance: .milliseconds(200))) != nil {
                guard let self else { return }
                refreshVisibleTimes()
            }
        }
    }

    private func refreshVisibleTimes() {
        let now = now()
        refreshVisiblePolls(now: now)
        guard settings.statusTimeStyle == .relative else { return }
        for cell in collectionView.visibleCells {
            (cell.contentView as? PostContentView)?.refreshTime(now: now)
        }
    }

    /// 表示中の投票のうち、残り時間や締め切りで見え方が変わったものだけを描き直す。表示したまま締め切りを迎えた投票を、投票できる形のまま残さないため。
    /// 投票の行の高さは形や残り時間で変わらないため、描き直しても並びは動かない。
    private func refreshVisiblePolls(now: Date) {
        var stale: Set<ItemID> = []
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  let poll = status(for: id)?.displayed.poll,
                  let drawn = (collectionView.cellForItem(at: indexPath)?.contentView as? PostContentView)?.pollDisplay,
                  PollDisplay(poll: poll, choices: pollChoices, now: now) != drawn else { continue }
            stale.insert(id)
        }
        reconfigure(stale)
    }

    /// チューニングの値、回線の状態、設定が変わったら、表示中の投稿を描き直す。
    /// サムネイルは、低データモードを抜けたときなどに、表示中のものも読む画像を選び直す。
    private func observeTuning() {
        withObservationTracking {
            _ = settings.appearanceValues
            _ = tuning.value(of: TuningCatalog.mediaThumbnailUpscaleTolerance)
            _ = tuning.value(of: TuningCatalog.xPostEmbeds)
            _ = tuning.value(of: TuningCatalog.reactionGlowMixesInOKLab)
            _ = tuning.value(of: TuningCatalog.reactionGlowIconRiseDelay)
            _ = tuning.value(of: TuningCatalog.reactionGlowHDRExposure)
            _ = tuning.value(of: TuningCatalog.reactionGlowLightIntensity)
            _ = tuning.value(of: TuningCatalog.reactionGlowLightBloomIntensityRatio)
            _ = tuning.value(of: TuningCatalog.reactionGlowDarkGlowHDRExposure)
            _ = network.usePolicy(settings: settings)
            _ = settings.ignoresUselessAltText
            _ = settings.statusNameStyle
            _ = settings.contextNameStyle
            _ = settings.showsVisibilitySymbol
            _ = settings.showsEditedMark
            _ = settings.showsLinkCardSite
            _ = settings.showsSeparators
            _ = settings.showsContextSymbol
            _ = settings.boldsName
            _ = settings.showsAvatarBorder
            _ = settings.showsMediaBadges
            _ = settings.showsLinkCard
            _ = settings.boldsLinkCardTitle
            _ = settings.showsBoosterAvatar
            _ = settings.showsReplyLabel
            _ = settings.showsReplyLines
            _ = settings.showsTime
            _ = settings.showsLinkCardImage
            _ = settings.statusTimeStyle
            _ = settings.avatarShape
            _ = settings.animatesAvatars
            _ = settings.animatesCustomEmojis
            _ = settings.linkCardThumbnailSide
            _ = settings.mediaArrangement
            _ = settings.tiltsStackedPhotos
            _ = settings.glyphLanguage
            _ = settings.emojiStyle
            _ = settings.drawsReactionGlowInHDR
            _ = settings.reactionGlowIcons
            _ = settings.reactionGlowFillsWidthWhenAlone
            _ = settings.reactionGlowLightFavouriteColor
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconfigure(Set(self.dataSource.snapshot().itemIdentifiers))
                // 区切り線はリストのレイアウトが引くので、描き直しでは変わらない。引き直させる。
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.observeTuning()
            }
        }
    }

    /// 絵文字の画像が届いたら、その絵文字を使う投稿だけを描き直す。読んでいる位置は保つ。
    /// 文字が横へずれたり次の行へ移ったりする動きは、ラベルが付ける（`EmojiArrivalTransition`）。
    /// 折り返しが変わって見えている行の高さが変わるときは、下の行ごと動かしてつなぐ（`reconfigureShiftingRowsBelow`）。
    /// リンクカードと同じ描き直し（`reconfigureAnimatingHeight`）にしないのは、1つの投稿の絵文字は続けて届き、
    /// 動いている途中に次の描き直しが重なると、一覧が行のセルを入れ替え、動かしているラベルが窓から外れて動きが止まるため（シミュレーターで確かめた）。
    private func emojiImagesDidLoad(_ urls: Set<URL>) {
        let ids = dataSource.snapshot().itemIdentifiers.filter { id in
            switch entries[id] {
            case .status(let status), .pinned(let status): !Self.emojiURLs(of: status, quoteSources: quoteSourceChanges).isDisjoint(with: urls)
            case .notification(let notification): !Self.emojiURLs(of: notification, quoteSources: quoteSourceChanges).isDisjoint(with: urls)
            case .account(let account): !Set(account.emojis.map(\.staticUrl)).isDisjoint(with: urls)
            case .gap, .unreadable, nil: false
            }
        }
        reconfigureShiftingRowsBelow(Set(ids), duration: tuning.value(of: TuningCatalog.customEmojiArrivalDuration))
    }

    /// 行の中身を、同じセルのまま動かさずに描き直し、高さが変わって位置がずれた見えている行と区切り線を、元の位置から新しい位置へ動かしてつなぐ。
    /// 上端が表示領域の上端より上にある行の高さが変わるときも、その行の位置は保ったまま、下の行を動かす（docs/vision.mdの「一覧の動き」）。
    /// 押し下げられて表示領域の外へ出る行は、描き直す前に取っておいた像を動かして外へ送る。
    ///
    /// 動きは、層の位置に足し合わせる形（additive）で付ける。描き直しを続けて重ねても、前の動きの途中の位置から次の動きがつながり、
    /// スクロールで一覧が行の位置を置き直しても、動きは外れない。差分を動きつきで当てる描き直しと違い、一覧がセルを入れ替えないので、
    /// セルの中で続いている動き（絵文字が入る文字の動きなど）も止まらない。
    /// 区切り線は、行のセルとは別のビューとして一覧に並ぶため、セルと一緒に動かす。動かさないと、伸びた行の下の線だけが1コマで下がる。
    func reconfigureShiftingRowsBelow(_ ids: Set<ItemID>, duration: TimeInterval) {
        guard !ids.isEmpty else { return }
        guard duration > 0, view.window != nil, !isShowingMenu, !UIAccessibility.isReduceMotionEnabled else {
            reconfigure(ids)
            return
        }
        let before = visibleRows(snapshottingBelow: ids)
        let separatorsBefore = visibleSeparators()
        reconfigure(ids)
        collectionView.layoutIfNeeded()
        let after = visibleRows(snapshottingBelow: [])
        // 動かす行と区切り線は、動かない行より手前に描く。伸びた行のセルは一度に高くなり、その背景が、下がってくる途中の下の行を隠すため。
        // `zPosition`を上げるとバーの下のぼかしより手前に出てしまうため、同じ`zPosition`のビューどうしの並び順で手前に出す（`MediaBarLayering`と同じ）。
        var moved: [UIView] = []
        for (id, old) in before {
            if let row = after[id] {
                if shiftRow(row.cell.layer, by: row.minY - old.minY, duration: duration) {
                    moved.append(row.cell)
                }
            } else if let indexPath = dataSource.indexPath(for: id), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame {
                // 押し下げられて表示領域の外へ出た行は、一覧がセルを外すので、描き直す前に取っておいた像を動かして外へ送る。
                let minY = collectionView.convert(frame, to: nil).minY
                sendOut(old.snapshot, from: old.minY, to: minY, duration: duration)
            }
        }
        for (key, separator) in visibleSeparators() {
            guard let old = separatorsBefore[key]?.minY else { continue }
            if shiftRow(separator.view.layer, by: separator.minY - old, duration: duration) {
                moved.append(separator.view)
            }
        }
        for view in moved {
            collectionView.bringSubviewToFront(view)
        }
    }

    /// 一覧に並ぶ区切り線のビューと、その画面（ウインドウ）での上端。区切り線はUIKitの非公開のビューなので、行のセルでも背景でもない、高さが細い線のビューとして見分ける。
    private func visibleSeparators() -> [ObjectIdentifier: (view: UIView, minY: CGFloat)] {
        collectionView.subviews.reduce(into: [:]) { result, view in
            guard !(view is UICollectionViewCell), !view.isHidden, view.bounds.height <= 2, view.bounds.width > 0 else { return }
            result[ObjectIdentifier(view)] = (view, view.convert(view.bounds, to: nil).minY)
        }
    }

    /// 足し合わせる行の動きに付ける名前を、重ねても取り替えないよう分ける。
    private var rowShiftCount = 0

    /// 層を、`shift`だけ前の位置から今の位置へ動かす。前の動きの途中なら、その動きは足し合わせたまま続く。動かしたらtrueを返す。
    @discardableResult
    private func shiftRow(_ layer: CALayer, by shift: CGFloat, duration: TimeInterval) -> Bool {
        guard abs(shift) > 0.5 else { return false }
        let move = CABasicAnimation(keyPath: "position")
        move.isAdditive = true
        move.fromValue = CGPoint(x: 0, y: -shift)
        move.toValue = CGPoint.zero
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rowShiftCount += 1
        layer.add(move, forKey: "rowShift\(rowShiftCount)")
        return true
    }

    /// 表示領域の外へ出た行の像を、前の位置から新しい位置へ動かしてから外す。
    private func sendOut(_ snapshot: UIView?, from oldMinY: CGFloat, to newMinY: CGFloat, duration: TimeInterval) {
        guard let snapshot, abs(newMinY - oldMinY) > 0.5 else { return }
        snapshot.isUserInteractionEnabled = false
        collectionView.addSubview(snapshot)
        let origin = collectionView.convert(CGPoint(x: 0, y: newMinY), from: nil)
        snapshot.frame.origin.y = origin.y
        shiftRow(snapshot.layer, by: newMinY - oldMinY, duration: duration)
        let remove = CABasicAnimation(keyPath: "opacity")
        remove.fromValue = 1
        remove.toValue = 1
        remove.duration = duration
        remove.delegate = RowShiftCompletion { snapshot.removeFromSuperview() }
        snapshot.layer.add(remove, forKey: "rowShiftEnd")
    }

    /// 見えている行の、画面（ウインドウ）での上端と、表示領域の外へ押し出されたときに動かす像。
    /// 画面の座標で比べるのは、読んでいる位置を保つためにスクロール位置を補正した分を、行の動きに数えないため。
    /// 動きの途中の行も、動きを足す前の位置で測る。前の動きは足し合わせたまま続くので、次の動きはずれた分だけを足せばつながる。
    /// - Parameter changed: 描き直す行。像は、そのうち一番上の見えている行より下の行だけ取る。行が大きく伸びると、その下の何行もが外へ押し出されるため。
    private func visibleRows(snapshottingBelow changed: Set<ItemID>) -> [ItemID: (cell: UICollectionViewCell, minY: CGFloat, snapshot: UIView?)] {
        let rows: [(id: ItemID, cell: UICollectionViewCell, minY: CGFloat)] = collectionView.visibleCells.compactMap { cell in
            guard let id = collectionView.indexPath(for: cell).flatMap({ dataSource.itemIdentifier(for: $0) }) else { return nil }
            return (id, cell, cell.convert(cell.bounds, to: nil).minY)
        }
        let changedTop = rows.filter { changed.contains($0.id) }.map(\.minY).min()
        return rows.reduce(into: [:]) { result, row in
            let snapshot = changedTop.map { row.minY > $0 } == true ? row.cell.snapshotView(afterScreenUpdates: false) : nil
            snapshot?.frame = row.cell.frame
            result[row.id] = (row.cell, row.minY, snapshot)
        }
    }

    /// 押し出された行の像を、動き終えたら外す。
    @MainActor
    private final class RowShiftCompletion: NSObject, @MainActor CAAnimationDelegate {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        func animationDidStop(_ animation: CAAnimation, finished: Bool) {
            handler()
        }
    }

    /// 通知のアイコンは文字に差し込んでいるため、届いたらその人からの通知を描き直す。投稿のアイコンはビューが自分で受け取る。
    private func avatarImageDidLoad(_ key: AvatarImageKey) {
        let ids = dataSource.snapshot().itemIdentifiers.filter { id in
            guard case .notification(let notification) = entries[id] else { return false }
            return avatarContent(of: notification.account).url == key.url
        }
        reconfigure(Set(ids))
    }

    /// 引用の囲みに出す引用元の本文、注意書き、作者の名前の絵文字も含める。引用元は、囲みと同じく受け取ったあとの変化を当てた版から集める。
    static func emojiURLs(of status: Status, quoteSources: QuoteSourceChanges) -> Set<URL> {
        let shown = status.displayed
        let quoted = quoteSources.applying(to: shown).quote?.quotedStatus.map { $0.emojis + $0.account.emojis } ?? []
        return Set((shown.emojis + (shown.poll?.emojis ?? []) + shown.account.emojis + status.account.emojis + quoted).map(\.staticUrl))
    }

    private static func emojiURLs(of notification: MastodonNotification, quoteSources: QuoteSourceChanges) -> Set<URL> {
        Set(notification.account.emojis.map(\.staticUrl)).union(notification.status.map { emojiURLs(of: $0, quoteSources: quoteSources) } ?? [])
    }

    /// 端末の文字の大きさが変わったら、行をすべて組み直し、変わる前に読んでいた位置へ戻す。
    private func contentSizeDidChange() {
        let anchor = contentSizeAnchor ?? currentAnchor()
        contentSizeAnchor = nil
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
        if let anchor {
            restore(anchor)
        }
    }

    /// 内容が変わってセルの高さが変わっても、読んでいる位置が動かないように描き直す。
    /// - Parameter anchorID: 画面上の位置を保つ要素。なければ、表示領域の上端にかかっている要素にする。
    func reconfigure(_ ids: Set<ItemID>, keeping anchorID: ItemID? = nil) {
        guard !ids.isEmpty else { return }
        guard !isShowingMenu else {
            heldReconfigureIDs.formUnion(ids)
            return
        }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(Array(ids))
        applyPreservingAnchor(snapshot, keeping: anchorID)
    }

    /// 行の中身を描き直し、高さが変わる分を、下の行ごとスプリングで動かしてつなぐ。動きの途中も操作を受け付ける。
    /// 上端が表示領域の上端より上にある行は、スプリングで伸ばすと読んでいる位置がずれるため、その行の位置を保って描き直し、
    /// 下の行と区切り線を動かしてつなぐ（`reconfigureShiftingRowsBelow`）。画面に出ていない行と、メニューを出している間は、動かさずに描き直す。
    func reconfigureAnimatingHeight(_ ids: Set<ItemID>, duration: TimeInterval) {
        guard !ids.isEmpty else { return }
        guard duration > 0, view.window != nil, !isShowingMenu, !UIAccessibility.isReduceMotionEnabled else {
            reconfigure(ids)
            return
        }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visible = Set(collectionView.indexPathsForVisibleItems)
        var animated: [ItemID] = []
        var others: Set<ItemID> = []
        for id in ids {
            if let indexPath = dataSource.indexPath(for: id), visible.contains(indexPath),
               let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame, frame.minY >= visibleTop {
                animated.append(id)
            } else {
                others.insert(id)
            }
        }
        // 上端が表示領域より上にある行は、その行の位置を保ったまま描き直し、下の行を動かしてつなぐ。
        reconfigureShiftingRowsBelow(others, duration: duration)
        guard !animated.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(animated)
        UIView.animate(springDuration: duration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.dataSource.apply(snapshot, animatingDifferences: true)
        }
    }

    /// 表示中の要素を、新しい順に並んだ`newEntries`で置き換える。
    ///
    /// 読んでいる位置の要素が画面上で動かないようにする。基準は表示領域の上端にかかっている要素で、`anchorID`を渡せばその要素にする。
    /// ただし最上部にいて追従が有効なら、最上部に留まって新着を見せる。ビューアや全画面のアプリ内のSafariで覆っている間は追従しない。
    /// `topID`を渡すと、その要素を表示領域の上端に置く。既読位置から読み始めるときに使う。
    /// - Parameter keepsOffset: 一覧の中身を取り替える。要素を基準にせず、スクロール位置をそのまま保つ。
    ///   プロフィールのタブの切り替えのように、ヘッダーを押した場所に残し、その下の中身だけを入れ替えたいときに使う。
    ///   新しい一覧が短くていまの位置までスクロールできなければ、末尾までスクロールしたところで止める。
    /// - Parameter animatesRemoval: 使う人の操作（フォローリクエストの承認、投稿の削除など）で行を消す。
    ///   操作の結果が分かるよう、消える行を閉じ、下の行を詰める動きで消す。消せないときは、ほかの更新と同じく動かさずに位置を保つ。
    /// - Parameter base: `newEntries`は、この並びに行を足すか除くかしただけで、残る行の中身を変えていない。
    ///   前回並べた配列と同じものなら、描き直す行を探すために行の中身を比べるのを省く。一覧が長いと、比べるだけで重くなるため。
    func setEntries(_ newEntries: [TimelineEntry], keeping anchorID: ItemID? = nil, placingAtTop topID: ItemID? = nil, keepsOffset: Bool = false, animatesRemoval: Bool = false, keepingRowContentsOf base: [TimelineEntry]? = nil) {
        guard !isShowingMenu else {
            // 後の呼び出しの並びが新しい。基準は、メニューが閉じたときに最後に指定されたものを使う。
            heldEntries = HeldEntries(
                entries: newEntries,
                anchorID: anchorID ?? heldEntries?.anchorID,
                topID: topID ?? heldEntries?.topID,
                keepsOffset: keepsOffset || (heldEntries?.keepsOffset ?? false),
                // 操作によらない変化と混ざったら、どれが操作の結果か分からないため、動かさない。
                animatesRemoval: heldEntries == nil && animatesRemoval
            )
            return
        }
        let previous = entries
        // 読み込み中の表示から最初の行を出すときは、表示を薄くしながら行を浮かび上がらせる。
        // 読み込みが速く、読み込み中の表示を画面に置く前に行が届いたときも、行は浮かび上がらせる。
        let revealsFromLoading = contentState == .loading && headerView == nil && previous.isEmpty && !newEntries.isEmpty
        let loadingSnapshot = revealsFromLoading ? loadingViewSnapshot() : nil
        let keepsRowContents = base.map { Self.sharesStorage($0, appliedEntries) } ?? false
        appliedEntries = newEntries
        // 添付ファイルのビューアや全画面のアプリ内のSafariで覆っている間は、新着を見たと報告しないので、追従もせずに読んでいた行の位置を保つ。
        let isCovered = isCoveredByMediaViewer || isCoveredByInAppBrowser
        let followsTop = anchorID == nil && topID == nil && isAtTop && !isCovered && tuning.value(of: TuningCatalog.followsNewArrivalsAtTop)
        let newIDs = newEntries.map(\.id)
        entries = Dictionary(zip(newIDs, newEntries), uniquingKeysWith: { _, new in new })
        gapIDs = newEntries.compactMap { entry in
            if case .gap(let gap) = entry { gap.id } else { nil }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newIDs)
        // 差分はIDで取られるため、同じIDのまま内容が変わった要素は明示的にセルを再構成する。
        let changedIDs = keepsRowContents ? [] : newEntries.filter { entry in previous[entry.id].map { $0 != entry } ?? false }.map(\.id)
        // 隣の行が変わって線のつながりだけが変わった行も描き直す。線は行の高さを変えないため、消す動きを止める理由にはしない。
        // 線のない行は前後とも線がないので、線のあった行と、ある行だけを比べる。
        let previousConnections = replyConnections
        replyConnections = ReplyConnection.connections(in: newEntries)
        let reconnectedIDs = Set(previousConnections.keys).union(replyConnections.keys).filter { id in
            previous[id] != nil && entries[id] != nil && previousConnections[id] != replyConnections[id]
        }
        snapshot.reconfigureItems(Array(reconnectedIDs.union(changedIDs)))
        if animatesRemoval, changedIDs.isEmpty, canAnimateRemoval(leaving: newIDs) {
            FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: true) }
            logger.info("setEntries count=\(newEntries.count, privacy: .public) animatesRemoval=true")
        } else if let topID {
            isRestoringAnchor = true
            FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
            scrollToTop(of: topID)
            isRestoringAnchor = false
            logger.info("setEntries count=\(newEntries.count, privacy: .public) top=\(Self.label(topID), privacy: .public)")
        } else if keepsOffset {
            isRestoringAnchor = true
            let offset = collectionView.contentOffset.y
            FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
            collectionView.layoutIfNeeded()
            let inset = collectionView.adjustedContentInset
            let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
            collectionView.contentOffset.y = min(offset, maxOffset)
            isRestoringAnchor = false
            logger.info("setEntries count=\(newEntries.count, privacy: .public) keepsOffset=true")
        } else if followsTop {
            // 最初に並べるときは、行が浮かび上がって見えないよう、アニメーションしない。
            let animates = !previous.isEmpty && settings.insertionMotion.animates(reducesMotion: UIAccessibility.isReduceMotionEnabled)
            if animates {
                // 行はアニメーションなしで足し、いままで最上部にあった行を同じ位置に残す。足した行の高さぶん下にずれた位置から、
                // 最上部へ1つの動きで戻して新着を見せる。
                applyPreservingAnchor(snapshot)
                scrollToTop(
                    duration: tuning.value(of: TuningCatalog.insertionScrollDuration),
                    bounce: tuning.value(of: TuningCatalog.insertionScrollBounce)
                )
            } else {
                isRestoringAnchor = true
                FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
                collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
                isRestoringAnchor = false
            }
            logger.info("setEntries count=\(newEntries.count, privacy: .public) followsTop=true animated=\(animates, privacy: .public)")
        } else {
            let anchor = applyPreservingAnchor(snapshot, keeping: anchorID)
            logger.info("setEntries count=\(newEntries.count, privacy: .public) anchor=\(anchor.map { Self.label($0.id) } ?? "nil", privacy: .public)")
        }
        if threadFocusID != nil {
            updateObscuredBottomInset()
        }
        setNeedsUpdateContentUnavailableConfiguration()
        if revealsFromLoading {
            revealFirstEntries(over: loadingSnapshot)
        }
        reportVisibleItems()
        reportApproachingGaps()
    }

    /// 全面に出している読み込み中の表示の像を、同じ位置に重ねて返す。表示を外したあとも、薄くし終えるまで残すため。
    private func loadingViewSnapshot() -> UIView? {
        let duration = tuning.value(of: TuningCatalog.accountSwitchDuration)
        guard duration > 0, view.window != nil, contentUnavailableConfiguration != nil,
              let shown = view.subviews.first(where: { $0 is UIContentUnavailableView }),
              let snapshot = shown.snapshotView(afterScreenUpdates: false)
        else { return nil }
        snapshot.frame = shown.frame
        snapshot.isUserInteractionEnabled = false
        view.addSubview(snapshot)
        return snapshot
    }

    /// 読み込み中の表示を外して最初の行を出したとき、表示の像を薄くし、見えている行を浮かび上がらせる。1コマで入れ替えないため。
    /// アカウントを切り替えたときと起動したときの、最初の読み込みで通る。
    private func revealFirstEntries(over loadingSnapshot: UIView?) {
        let duration = tuning.value(of: TuningCatalog.accountSwitchDuration)
        if let loadingSnapshot {
            UIView.animateSmoothly(duration: duration * 0.6) {
                loadingSnapshot.alpha = 0
            } completion: {
                loadingSnapshot.removeFromSuperview()
            }
        }
        fadeInVisibleItems(duration: duration)
    }

    /// 行を消すだけの更新を、閉じる動きで当てられるか。
    /// 行を足すときと、表示領域の上端より上の行が消えるときは動かさない。上の行を詰めると、読んでいる行が上へずれるため。
    /// 残る行の中身が変わるときも、呼び出し側で除く。高さが変わると、読んでいる行がずれうるため。
    /// 視差効果を減らす設定では、動きで伝えずに消す。
    private func canAnimateRemoval(leaving newIDs: [ItemID]) -> Bool {
        guard view.window != nil, !UIAccessibility.isReduceMotionEnabled else { return false }
        let currentIDs = dataSource.snapshot().itemIdentifiers
        let remaining = Set(newIDs)
        let removed = currentIDs.filter { !remaining.contains($0) }
        guard !removed.isEmpty, remaining.isSubset(of: currentIDs) else { return false }
        collectionView.layoutIfNeeded()
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return removed.allSatisfy { id in
            guard let indexPath = dataSource.indexPath(for: id),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { return false }
            return frame.minY >= visibleTop
        }
    }

    /// 画面に見えている行を、透明からフェードで出す。行を入れた直後に呼ぶ。
    /// 一覧全体をクロスフェードすると、途中でスクロールしたときに前の見た目が残像として重なるため、行だけを動かす。
    /// フェードの途中にスクロールで入ってきた行は、フェードせずにそのまま出す。0秒か、画面に出ていなければ何もしない。
    func fadeInVisibleItems(duration: TimeInterval) {
        guard duration > 0, view.window != nil else { return }
        collectionView.layoutIfNeeded()
        let cells = collectionView.visibleCells
        for cell in cells {
            cell.alpha = 0
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            for cell in cells {
                cell.alpha = 1
            }
        }
    }

    /// 読み込み中のギャップを読み込み中の表示に、読めなかったギャップを読めなかった表示にする。
    func setGapStates(loading ids: Set<String>, failures: [String: ErrorPresentation]) {
        let failureChanged = Set(failures.keys).union(gapFailures.keys).filter { failures[$0] != gapFailures[$0] }
        let changed = ids.symmetricDifference(loadingGapIDs).union(failureChanged).map(ItemID.gap)
        loadingGapIDs = ids
        gapFailures = failures
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        reconfigure(Set(changed).intersection(existing))
    }

    /// 最上部にいる。新着を挿入したときに追従するかの判定に使う。
    var isAtTop: Bool {
        collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 0.5
    }

    /// 指でスクロールしている、または指を離した後の慣性で動いている。
    var isUserScrolling: Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }

    /// スクロールしている、または長押しのメニューを出している。新着を挿入するのは、これが終わってからにする。
    var isUserInteracting: Bool {
        isUserScrolling || isShowingMenu
    }

    /// 2つの配列が同じ記憶域を指している。指していれば、中身も同じ。
    /// 前回並べた配列をここで持っているので、渡した側が並びを書き換えると、書き換えた側の配列は別の記憶域へコピーされる。
    /// 同じ中身でも記憶域が違えばfalseになり、そのときは行の中身を比べる。
    private static func sharesStorage(_ lhs: [TimelineEntry], _ rhs: [TimelineEntry]) -> Bool {
        lhs.count == rhs.count && lhs.withUnsafeBufferPointer { lhs in
            rhs.withUnsafeBufferPointer { rhs in lhs.baseAddress == rhs.baseAddress }
        }
    }

    private struct HeldEntries {
        let entries: [TimelineEntry]
        let anchorID: ItemID?
        let topID: ItemID?
        let keepsOffset: Bool
        let animatesRemoval: Bool
    }

    /// 長押しのメニューを出した。メニューの元になった行が動かないよう、閉じるまで一覧の並びの更新と描き直しを溜めておく。
    func menuWillShow() {
        isShowingMenu = true
    }

    /// メニューが閉じた。溜めていた更新を反映する。
    func menuDidHide() {
        guard isShowingMenu else { return }
        isShowingMenu = false
        if let held = heldEntries {
            heldEntries = nil
            setEntries(held.entries, keeping: held.anchorID, placingAtTop: held.topID, keepsOffset: held.keepsOffset, animatesRemoval: held.animatesRemoval)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let reconfigureIDs = heldReconfigureIDs.intersection(existing)
        heldReconfigureIDs.removeAll()
        reconfigure(reconfigureIDs)
        if let pending = pendingTextSelection {
            pendingTextSelection = nil
            // 溜めていた更新で、行が別の投稿に使い回されていれば選ばない。
            if pending.body.content?.statusID == pending.statusID {
                beginTextSelection(in: pending.body, statusID: pending.statusID)
            }
        }
        onInteractionSettle?()
    }

    /// `setUnreadCount`を呼んだ回数。新着ボタンを描き直す前の並べ直しの中から呼ばれたかを見分ける。
    private var unreadCountUpdates = 0

    /// 既読より新しい投稿の数。0なら新着ボタンを隠す。
    /// - Parameter isLowerBound: 未読の区間に読み込んでいない投稿があり、実際はもっと多い。
    func setUnreadCount(_ count: Int, isLowerBound: Bool = false) {
        unreadCount = count
        unreadCountUpdates += 1
        let update = unreadCountUpdates
        // 通知のタブのバッジと同じく、読み込んでいない分があるときは「+」を付ける。
        let title = isLowerBound ? "\(count)+" : "\(count)"
        newArrivalsButton.accessibilityLabel = isLowerBound ? "\(count)件以上の新着" : "\(count)件の新着"
        if newArrivalsButton.configuration?.title != title {
            // 桁が変わると幅が変わるため、出ている間は前後のカプセルをクロスフェードする。幅を伸ばすと、伸びる途中で件数の文字が切れるため。
            if newArrivalsButtonShown, view.window != nil {
                // 待っている並べ直しは、クロスフェードの前に済ませる。中で済ませると、ボタンと関係のない行やメディアまで動きに乗るため。
                view.layoutIfNeeded()
                // 並べ直しでスクロール位置が補正されて既読が進むと、その中から新しい件数で呼ばれ、表示を済ませている。古い件数で上書きしない。
                guard update == unreadCountUpdates else { return }
                UIView.transition(with: newArrivalsButton, duration: newArrivalsButtonDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    self.newArrivalsButton.configuration?.title = title
                    self.view.layoutIfNeeded()
                }
            } else {
                newArrivalsButton.configuration?.title = title
            }
        }
        updateNewArrivalsButtonVisibility()
    }

    private var newArrivalsButtonDuration: TimeInterval {
        tuning.value(of: TuningCatalog.newArrivalsButtonDuration)
    }

    /// 最上部へ動かしている間は隠す。新着を足して最上部へ動かすときに、新着が画面に入るまでの間だけ出てしまうため。
    /// 出し入れは濃さで動かす。消え終えてから隠すので、消える途中にまた出すときは、見えている濃さから戻す。
    private func updateNewArrivalsButtonVisibility() {
        let isShown = unreadCount > 0 && !isScrollingToTop
        guard newArrivalsButtonShown != isShown else { return }
        newArrivalsButtonShown = isShown
        let button = newArrivalsButton
        button.isUserInteractionEnabled = isShown
        guard view.window != nil else {
            button.alpha = isShown ? 1 : 0
            button.isHidden = !isShown
            return
        }
        if isShown, button.isHidden {
            button.alpha = 0
            button.isHidden = false
        }
        newArrivalsButtonGeneration += 1
        let generation = newArrivalsButtonGeneration
        UIView.animateSmoothly(duration: newArrivalsButtonDuration) {
            button.alpha = isShown ? 1 : 0
        } completion: {
            guard generation == self.newArrivalsButtonGeneration, !self.newArrivalsButtonShown else { return }
            button.isHidden = true
        }
    }

    // MARK: アプリ内通知

    /// 押し直せば済む失敗を、チップの列に数秒出す。決まりはdocs/notices.mdの「置き場所」にある。
    func showNotice(_ notice: Notice) {
        showNotice(notice, duration: tuning.value(of: TuningCatalog.noticeFailureChipDuration))
    }

    /// 数秒で消えるアプリ内通知を出す。
    func showNotice(_ notice: Notice, duration: TimeInterval) {
        notices?.showTransient(notice, duration: duration)
    }

    /// ストリーミングにつながらない状態が続いていることを、タイトルの下に控えめに出す。題の下に添える文字があれば、その後ろに並べる。
    func setOutageNotice(_ isShown: Bool) {
        let parts = [texts.subtitle, isShown ? "ストリーミング切断中" : nil].compactMap(\.self)
        navigationItem.subtitle = parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    func setContentState(_ state: ContentState) {
        contentState = state
        setNeedsUpdateContentUnavailableConfiguration()
    }

    func setFooterState(_ state: FooterState) {
        footerState = state
        if let footer = collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter).first as? TimelineFooterView {
            configure(footer)
        }
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard headerView == nil, dataSource.snapshot().numberOfItems == 0 else {
            contentUnavailableConfiguration = nil
            return
        }
        contentUnavailableConfiguration = contentUnavailableConfiguration(for: contentState)
    }

    /// 投稿が1件もないときに、一覧の全面に出す表示。
    func contentUnavailableConfiguration(for state: ContentState) -> UIContentUnavailableConfiguration {
        switch state {
        case .loading:
            return UIContentUnavailableConfiguration.loading()
        case .loaded:
            return emptyConfiguration(text: texts.empty, secondaryText: nil, buttonTitle: "再読み込み")
        case .regenerating:
            return emptyConfiguration(
                text: "ホームを準備しています",
                secondaryText: "しばらく使っていなかったため、サーバーがホームを作り直しています。少し待ってから読み込み直してください。",
                buttonTitle: "再読み込み"
            )
        case .failed(let message):
            var configuration = emptyConfiguration(text: "読み込めませんでした", secondaryText: nil, buttonTitle: "再試行")
            configuration.secondaryAttributedText = message.attributedText(textStyle: .body)
            return configuration
        }
    }

    /// 投稿がない状態から読み込み直せるよう、どの表示にも再試行ボタンを置く。
    private func emptyConfiguration(text: String, secondaryText: String?, buttonTitle: String) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = text
        configuration.secondaryText = secondaryText
        configuration.button = .borderedTinted()
        configuration.button.title = buttonTitle
        configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onRetry?() }
        return configuration
    }

    /// 違和感レポートに含める、スクロール位置と表示中の投稿の状態。
    func stateDump() -> String {
        let visibleIDs = collectionView.indexPathsForVisibleItems.sorted().compactMap { dataSource.itemIdentifier(for: $0) }.map(Self.label)
        let anchor = currentAnchor()
        return """
        items: \(dataSource.snapshot().numberOfItems)
        contentOffset.y: \(collectionView.contentOffset.y)
        contentSize.height: \(collectionView.contentSize.height)
        adjustedContentInset.top: \(collectionView.adjustedContentInset.top)
        contentInset.top: \(collectionView.contentInset.top) refreshing: \(refreshControl.isRefreshing) refreshFrame: \(refreshControl.frame)
        visibleItems: \(visibleIDs.joined(separator: ", "))
        anchor: \(anchor.map { "\(Self.label($0.id)) distanceFromVisibleTop=\($0.distanceFromVisibleTop)" } ?? "nil")
        lastScrollDirection: \(lastScrollDirection.map { "\($0)" } ?? "nil")
        contentState: \(contentState)
        footerState: \(footerState)
        isAtTop: \(isAtTop)
        unreadCount: \(unreadCount)
        loadingGaps: \(loadingGapIDs.sorted().joined(separator: ", "))
        failedGaps: \(gapFailures.keys.sorted().joined(separator: ", "))
        """
    }

    /// ログと状態ダンプで要素を示す表記。投稿はID、ギャップは`gap-`で始まるID。
    private static func label(_ id: ItemID) -> String {
        switch id {
        case .status(let id): id
        case .gap(let id): id
        case .notification(let id): "notification-\(id)"
        case .pinned(let id): "pinned-\(id)"
        case .unreadable(let id): "unreadable-\(id)"
        case .account(let id): "account-\(id)"
        }
    }

    /// 表示している投稿のID。上から順。ギャップは含めない。
    var displayedStatusIDs: [Status.ID] {
        dataSource.snapshot().itemIdentifiers.compactMap { id in
            if case .status(let statusID) = id { statusID } else { nil }
        }
    }

    /// 表示している要素のID。上から順。
    var displayedItemIDs: [ItemID] {
        dataSource.snapshot().itemIdentifiers
    }

    func itemIdentifier(at indexPath: IndexPath) -> ItemID? {
        dataSource.itemIdentifier(for: indexPath)
    }

    func entry(for id: ItemID) -> TimelineEntry? {
        entries[id]
    }

    /// 一覧の位置にある要素。
    func itemID(at indexPath: IndexPath) -> ItemID? {
        dataSource.itemIdentifier(for: indexPath)
    }

    /// 違和感レポートの操作の記録に残す、画面の名前。
    var screenName: String {
        texts.dumpName
    }

    /// 一覧の行にいる、そのIDのアカウント。いなければnil。
    func account(withID id: String) -> Account? {
        Self.account(withID: id, in: entries.values)
    }

    /// 一覧の投稿のメンションのうち、リンク先が`url`の人。本文のメンションのリンクにはIDがないため、投稿のメンションの一覧から引く。
    func mention(withURL url: URL) -> Mention? {
        Self.mention(withURL: url, in: entries.values)
    }

    /// 行の投稿（ブーストなら元の投稿も、通知なら対象の投稿も）のメンションから、リンク先が`url`の人を探す。
    static func mention(withURL url: URL, in entries: some Sequence<TimelineEntry>) -> Mention? {
        for entry in entries {
            let statuses: [Status] = switch entry {
            case .status(let status), .pinned(let status): [status, status.reblog].compactMap(\.self)
            case .notification(let notification): [notification.status, notification.status?.reblog].compactMap(\.self)
            case .account, .gap, .unreadable: []
            }
            for status in statuses {
                if let mention = status.mentions.first(where: { $0.url == url }) {
                    return mention
                }
            }
        }
        return nil
    }

    /// 行の投稿した人、ブーストした人、通知した人（まとめた通知なら並べた人）、人の一覧の人から、そのIDのアカウントを探す。
    static func account(withID id: String, in entries: some Sequence<TimelineEntry>) -> Account? {
        for entry in entries {
            let accounts: [Account] = switch entry {
            case .status(let status), .pinned(let status): [status.account, status.reblog?.account].compactMap(\.self)
            case .notification(let notification): notification.sampleAccounts + [notification.status?.account, notification.status?.reblog?.account].compactMap(\.self)
            case .account(let account): [account]
            case .gap, .unreadable: []
            }
            if let account = accounts.first(where: { $0.id == id }) {
                return account
            }
        }
        return nil
    }

    /// 要素の行。画面の外にあればnil。
    func cell(for id: ItemID) -> UICollectionViewCell? {
        dataSource.indexPath(for: id).flatMap(collectionView.cellForItem(at:))
    }

    private func makeNewArrivalsButton() -> UIButton {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "arrow.up")
        // ボタンが件数の文字に合わせて決める矢印の大きさを、一段小さくする。既定のままでは件数より大きく見えるため。
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .small)
        configuration.imagePadding = 1
        configuration.buttonSize = .small
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            // 慣性で動いている途中なら、それまでのスクロールが先に記録されるよう、動かしてから記録する。
            scrollToNewest()
            UserAction.tapNewArrivals(screen: texts.dumpName).record()
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.alpha = 0
        return button
    }

    /// 投稿が一覧にあれば、覆われていない表示領域の下端に来るまでスクロールする。返信先のラベルから、書いている入力欄のすぐ上に返信先を出すために使う。
    /// 同じ投稿が元の投稿とブースト、通知などで何か所にも並ぶことがあるため、まず返信を選んだ要素そのもの（ブーストならブーストのID）を探し、
    /// なければ中身が同じ投稿（`displayedID`、ブーストなら元の投稿のID）を探す。一覧になければ動かさずにfalseを返す。
    @discardableResult
    func scrollToStatus(_ statusID: Status.ID, displayedID: Status.ID? = nil, at position: UICollectionView.ScrollPosition = .bottom, animated: Bool = true) -> Bool {
        let displayedID = displayedID ?? statusID
        let ids = displayedItemIDs
        let chosen = ids.first { id in
            switch entries[id] {
            // 固定投稿は、同じ投稿が下の一覧にも並ぶことがあり、IDでは見分けられない。上にある固定投稿の方へ移る。
            case .status(let status), .pinned(let status): status.id == statusID
            case .notification(let notification): notification.status?.id == statusID
            case .gap, .unreadable, .account, nil: false
            }
        }
        let found = chosen ?? ids.first { id in
            switch entries[id] {
            case .status(let status), .pinned(let status): status.displayed.id == displayedID
            case .notification(let notification): notification.status?.displayed.id == displayedID
            case .gap, .unreadable, .account, nil: false
            }
        }
        guard let found, let indexPath = dataSource.indexPath(for: found) else { return false }
        if animated {
            // 最上部へ動かしている途中なら、速さを持ち越して行き先だけ替える。
            startSpringScroll(
                to: .item(found, position),
                duration: tuning.value(of: TuningCatalog.scrollToStatusDuration),
                bounce: tuning.value(of: TuningCatalog.scrollToStatusBounce)
            )
        } else {
            // 最上部へ動かしている途中なら、それをやめる。続けると、投稿へ動かした位置と取り合う。
            stopSpringScroll()
            collectionView.scrollToItem(at: indexPath, at: position, animated: false)
        }
        return true
    }

    /// 画面の下端から、投稿欄のキーボードと入力バー、アプリ内のSafariのシートが覆っている高さ。
    private var obscuredBottomHeight: CGFloat = 0

    /// アプリ内のSafariを全画面に広げて、一覧を覆っている。
    private var isCoveredByInAppBrowser = false

    /// アプリ内のSafariは後ろに一覧を残したまま全画面に広がるため、広げている間は一覧の投稿を見たと報告しない。
    /// 中くらいの高さに戻したら、そこで見えている投稿を報告し直す。
    func setCoveredByInAppBrowser(_ covered: Bool) {
        guard isCoveredByInAppBrowser != covered else { return }
        isCoveredByInAppBrowser = covered
        if covered {
            onVisibleLinkOnlyCardsChange?([])
        } else {
            reportVisibleItems()
        }
    }

    /// 下端の覆われた部分を一覧の表示領域から外し、そこに隠れた要素を表示中として報告しないようにする。
    /// 下側の余白を変えるだけなので、上端を基準にした読んでいる位置は動かない。ただし一覧の末尾までスクロールしていると、
    /// 下端を覆うものがなくなったときに末尾が下端に合わせて下がる。末尾は古い投稿を読み込む途中で留まる場所ではなく、そこで書き始めることはまれなため、補正しない。
    func setObscuredBottomHeight(_ height: CGFloat) {
        obscuredBottomHeight = height
        updateObscuredBottomInset()
    }

    /// タブバーや投稿欄のアクセサリーの分はsafe areaに入っているため、それを超えて覆っている分だけ足す。
    /// 画面を読み込む前は値だけを覚え、読み込んだあとのsafe areaの変化で反映する。ここで読み込むと、画面を組み立てる前に置くボタンなどの設定より先に読み込まれてしまう。
    /// スレッドでは、押した投稿を表示領域の上端まで上げられるだけの余白も、一覧の下に足す。
    private func updateObscuredBottomInset() {
        guard isViewLoaded else { return }
        let inset = max(0, obscuredBottomHeight - view.safeAreaInsets.bottom)
        let total = inset + threadFocusBottomFill(obscuredInset: inset)
        guard collectionView.contentInset.bottom != total || collectionView.verticalScrollIndicatorInsets.bottom != inset else { return }
        collectionView.contentInset.bottom = total
        collectionView.verticalScrollIndicatorInsets.bottom = inset
        reportVisibleItems()
    }

    /// 押した投稿から下の行が表示領域の高さに足りない分。足りないと、押した投稿を押した位置に置いたままにできず、一覧が端まで戻ってしまうため。
    private func threadFocusBottomFill(obscuredInset: CGFloat) -> CGFloat {
        guard let threadFocusID, let indexPath = dataSource.indexPath(for: .status(threadFocusID)) else { return 0 }
        collectionView.layoutIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return 0 }
        let visibleHeight = collectionView.bounds.height - collectionView.adjustedContentInset.top - view.safeAreaInsets.bottom - obscuredInset
        return max(visibleHeight - (collectionView.contentSize.height - frame.minY), 0)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateObscuredBottomInset()
    }

    /// 新着ボタン、タブの選び直し、ステータスバーのタップで、最上部へ戻る。
    func scrollToNewest() {
        // 慣性で動いている途中にこちらで動かすと、止まりの通知が来ないため、ここまでのスクロールを記録する。
        recordScroll()
        scrollToTop(
            duration: tuning.value(of: TuningCatalog.scrollToTopDuration),
            bounce: tuning.value(of: TuningCatalog.scrollToTopBounce)
        )
    }

    /// スプリングで動かす行き先。
    private enum SpringScrollDestination: Equatable {
        case top
        /// 行が表示領域の`position`に来る位置。
        case item(ItemID, UICollectionView.ScrollPosition)
    }

    /// 最上部へスプリングで動かす。
    private func scrollToTop(duration: TimeInterval, bounce: Double) {
        startSpringScroll(to: .top, duration: duration, bounce: bounce)
    }

    /// 行き先へスプリングで動かす。UIKitのスクロールのアニメーションは時間も曲線も変えられないため、毎フレーム位置を置く。
    ///
    /// まだ表示していないセルは見積もりの高さで並び、表示されたときに実寸へ変わる。上のセルが変わるとUICollectionViewがそのぶん位置を補正し、
    /// 行き先の行の位置も変わる。動いている途中に新着を足したときも、読んでいる位置を保つためにずらす。
    /// 毎フレーム行き先を測り直し、ずれた位置から速さを持ち越して向かうため、中身は飛ばず、止まり直しもしない。
    /// UIKitのアニメーションは動き始めに見積もりで行き先を決めるため、途中でコマが飛ぶと、行き先の行が画面の外に残ることがある。
    /// すでに動かしていれば、速さを持ち越して行き先と時間とバウンスだけ替える。動いている途中に指が触れたら止め、指の操作に任せる。
    private func startSpringScroll(to destination: SpringScrollDestination, duration: TimeInterval, bounce: Double) {
        springScrollDestination = destination
        springScroll = SpringScroll(duration: duration, bounce: bounce, velocity: springScroll?.velocity ?? 0)
        if springScrollTicker == nil {
            // 慣性で動いている途中なら止める。止めないと、慣性で動かす位置と取り合う。
            collectionView.setContentOffset(collectionView.contentOffset, animated: false)
            // 動いている途中にこの画面が閉じられて解放されたら、続けないと返して止めさせる。
            let ticker = FrameTicker(source: frameSource) { [weak self] elapsed in
                guard let self else { return false }
                stepSpringScroll(elapsed: elapsed)
                return springScrollTicker != nil
            }
            springScrollTicker = ticker
            springScrollInterruption.isEnabled = true
            ticker.start()
        }
        updateNewArrivalsButtonVisibility()
    }

    /// 最上部にいるときのスクロール位置。
    private var topOffset: CGFloat {
        -collectionView.adjustedContentInset.top
    }

    private func stepSpringScroll(elapsed: CFTimeInterval) {
        // 指が触れた時点で止める。ドラッグが始まるのを待つと、触れてから指が動くまでの間も動き続け、指の下で中身がずれる。
        // 行き先の行が一覧からなくなったときも止める。
        guard !collectionView.isTracking, var scroll = springScroll, let target = springScrollTarget() else {
            stopSpringScroll()
            return
        }
        let next = scroll.step(from: collectionView.contentOffset.y, toward: target, by: elapsed)
        springScroll = scroll
        guard !scroll.isSettled(at: next, target: target) else {
            didFinishSpringScroll(at: target)
            return
        }
        collectionView.contentOffset.y = next
    }

    /// 行き先のスクロール位置。行き先の行がなければnil。セルが実寸へ変わると行の位置も変わるため、毎フレーム測り直す。
    private func springScrollTarget() -> CGFloat? {
        guard case .item(let id, let position) = springScrollDestination else { return topOffset }
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return nil }
        let inset = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - inset.top - inset.bottom
        let offset = switch position {
        case .top: frame.minY - inset.top
        case .centeredVertically: frame.midY - inset.top - visibleHeight / 2
        default: frame.maxY - inset.top - visibleHeight
        }
        let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, topOffset)
        return min(max(offset, topOffset), maxOffset)
    }

    /// 落ち着いたら行き先にそろえる。新着ボタンは、見えた投稿を既読にしてから出し直す。先に出すと、既読になるまでの一瞬だけ出てしまう。
    private func didFinishSpringScroll(at target: CGFloat) {
        endSpringScroll()
        collectionView.contentOffset.y = target
        reportVisibleItemsAfterLayout()
        updateNewArrivalsButtonVisibility()
        onInteractionSettle?()
    }

    private func stopSpringScroll() {
        endSpringScroll()
        updateNewArrivalsButtonVisibility()
    }

    private func endSpringScroll() {
        springScrollTicker?.stop()
        springScrollTicker = nil
        springScroll = nil
        // 触れて止めたときは、指が離れるまで有効のままにする。途中で無効にすると、止めた指のタッチが中身に渡る。
        if !springScrollInterruption.isHolding {
            springScrollInterruption.isEnabled = false
        }
    }

    /// 最上部へスプリングで動かしている。
    var isScrollingToTop: Bool {
        springScrollTicker != nil && springScrollDestination == .top
    }

    private func makeSpringScrollInterruption() -> TouchHoldGestureRecognizer {
        let recognizer = TouchHoldGestureRecognizer()
        recognizer.isEnabled = false
        recognizer.delegate = self
        recognizer.onHold = { [weak self] in self?.stopSpringScroll() }
        recognizer.onRelease = { [weak self] in
            guard let self, springScrollTicker == nil else { return }
            springScrollInterruption.isEnabled = false
        }
        return recognizer
    }

    /// 表示領域から一定の距離に入ったギャップを報告する。指で動かしている間と慣性で動いている間は、上へ戻っているなら
    /// 下の投稿に続く古い側から、下へ読み進めているなら上の投稿に続く新しい側から読ませる。止まっているときは、画面上の位置で決める。
    /// 止まった後の再接続などでできたギャップに、前の操作の向きを当てると、読んでいる投稿の反対側を基準にしてしまうため。
    private func reportApproachingGaps() {
        guard let onGapApproach, !isRestoringAnchor, !isScrollingToTop, !gapIDs.isEmpty else { return }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let distance = tuning.value(of: TuningCatalog.gapAutoLoadDistance) * visibleRect.height
        let zone = visibleRect.insetBy(dx: 0, dy: -distance)
        for gapID in gapIDs where !loadingGapIDs.contains(gapID) {
            guard let indexPath = dataSource.indexPath(for: .gap(gapID)),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                  frame.intersects(zone)
            else { continue }
            let isScrolling = collectionView.isTracking || collectionView.isDecelerating
            let direction: TimelineStore.GapDirection = switch isScrolling ? lastScrollDirection : nil {
            case .towardNewer: .fromOlder
            case .towardOlder: .fromNewer
            case nil: frame.midY < visibleRect.midY ? .fromOlder : .fromNewer
            }
            onGapApproach(gapID, direction)
        }
    }

    /// スクロールが止まったときに、レイアウトを確定させてから表示中の要素を報告し直す。
    /// スクロールの通知の時点では表示中のセルの一覧が前のフレームのままで、遠くから一気に動くと、
    /// 最後の通知に止まった位置の要素が入らないため。
    private func reportVisibleItemsAfterLayout() {
        collectionView.layoutIfNeeded()
        reportVisibleItems()
    }

    /// 表示領域に半分以上入っている投稿と通知を、表示中として報告する。ナビゲーションバーの下に隠れている部分は数えない。
    /// 他のタブにいる間や、添付ファイルのビューアや全画面のアプリ内のSafariで覆っている間など、画面に出ていなければ報告しない。
    func reportVisibleItems() {
        guard !isRestoringAnchor, viewIfLoaded?.window != nil, !isCoveredByMediaViewer, !isCoveredByInAppBrowser else { return }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let ids = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> ItemID? in
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return nil }
            let visibleHeight = frame.intersection(visibleRect).height
            guard visibleHeight >= min(frame.height, visibleRect.height) / 2 else { return nil }
            return dataSource.itemIdentifier(for: indexPath)
        }
        onVisibleStatusesChange?(ids.compactMap { id in
            if case .status(let statusID) = id { statusID } else { nil }
        })
        onVisibleNotificationsChange?(ids.compactMap { id in
            if case .notification(let notificationID) = id { notificationID } else { nil }
        })
        onVisibleLinkOnlyCardsChange?(linkOnlyCardStatuses(among: ids))
        prefetchMediaIfSettled(among: ids)
    }

    /// スクロールが止まっていれば、`ids`の行に出ている画像を先読みする（docs/image-loading.mdの「ビューアで開く画像の先読み」）。
    /// 動いている間は止め、流し見で通り過ぎた投稿を読まない。止まったときに差し替え、画面から外れた画像の読み込みを止める。
    private func prefetchMediaIfSettled(among ids: [ItemID]) {
        guard let mediaPrefetcher else { return }
        guard !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating, springScroll == nil else {
            mediaPrefetcher.prefetch([])
            return
        }
        let attachments = ids.flatMap { id -> [MediaAttachment] in
            guard let indexPath = dataSource.indexPath(for: id), let contentView = collectionView.cellForItem(at: indexPath)?.contentView else { return [] }
            let post = contentView as? PostContentView
            let grids = [post?.mediaGrid, post?.embedMediaGrid, (contentView as? NotificationContentView)?.mediaGrid]
            return grids.compactMap { $0?.content?.attachments }.flatMap { $0 }
        }
        mediaPrefetcher.prefetch(attachments)
    }

    /// `ids`の行のうち、リンク先だけのカードを出している投稿。通知でカードを出さない行は除くため、組み立てた中身で見分ける。
    private func linkOnlyCardStatuses(among ids: [ItemID]) -> [Status] {
        ids.compactMap { id -> Status? in
            guard let indexPath = dataSource.indexPath(for: id),
                  let configuration = collectionView.cellForItem(at: indexPath)?.contentConfiguration as? PostContentConfiguration,
                  case .link = configuration.card?.card
            else { return nil }
            return status(for: id)?.displayed
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.footerMode = .supplementary
        configuration.headerMode = headerView == nil ? .none : .supplementary
        // ヘッダー画像をナビゲーションバーのすぐ下から置く。
        configuration.headerTopPadding = 0
        // お気に入りやブーストで下の端が光っている行は、光の線を区切りにする。区切り線が光の線に重なると、光源が灰色に濁って見えるため。
        // 線で下の行とつながっている行も、区切り線を出さない。つながった行を1つの会話として見せるため。
        configuration.itemSeparatorHandler = { [weak self] indexPath, separator in
            var separator = separator
            guard let self, let id = self.dataSource.itemIdentifier(for: indexPath) else { return separator }
            guard self.settings.showsSeparators else {
                separator.topSeparatorVisibility = .hidden
                separator.bottomSeparatorVisibility = .hidden
                return separator
            }
            if let shown = self.status(for: id)?.displayed, shown.favourited || shown.reblogged {
                separator.bottomSeparatorVisibility = .hidden
            }
            if self.replyConnections[id]?.below == true {
                separator.bottomSeparatorVisibility = .hidden
            }
            return separator
        }
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            // plainのリストはフッターを表示範囲の下端に貼り付ける。貼り付いたフッターは、中身がなくてもタブバーのすぐ上を覆ってタップを吸うため、一覧の末尾に置く。
            for item in section.boundarySupplementaryItems {
                item.pinToVisibleBounds = false
            }
            return section
        }
    }

    private func configure(_ cell: TimelineCell, for entry: TimelineEntry, id: ItemID) {
        switch entry {
        case .status(let status):
            cell.contentConfiguration = contentConfiguration(for: status, itemID: id, base: cell.defaultContentConfiguration())
        case .pinned(let status):
            cell.contentConfiguration = contentConfiguration(for: status, isPinned: true, itemID: id, base: cell.defaultContentConfiguration())
        case .gap(let gap):
            cell.contentConfiguration = gapContentConfiguration(
                isLoading: loadingGapIDs.contains(gap.id),
                failure: gapFailures[gap.id],
                base: cell.defaultContentConfiguration()
            )
        case .notification(let notification):
            cell.contentConfiguration = contentConfiguration(for: notification, itemID: id, base: cell.defaultContentConfiguration())
        case .unreadable(let item):
            cell.contentConfiguration = unreadableContentConfiguration(for: item, base: cell.defaultContentConfiguration())
        case .account(let account):
            cell.contentConfiguration = accountConfiguration(for: account, base: cell.defaultContentConfiguration())
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, ItemID> {
        let registration = UICollectionView.CellRegistration<TimelineCell, ItemID> { [weak self] cell, _, id in
            guard let self, let entry = self.entries[id] else { return }
            // 別の行を出し始めたセルは、中身を動きの外で並べる。Macでウインドウの幅を変えたときのように、一覧が動きの中で並べ直すと、
            // 初めて画面に入った行の写真やボタンまで動きに乗り、大きさ0の左上から滑ってきて見えるため。
            // 同じ行の描き直し（リンクカードが届いたときなど）は、これまでどおり呼んだ側の動きに任せる。
            let startsNewRow = cell.itemID != id
            cell.itemID = id
            cell.workName = entry.workName
            FrameWork.measure("\(entry.workName).configure") { self.configure(cell, for: entry, id: id) }
            if startsNewRow {
                UIView.performWithoutAnimation { cell.layoutIfNeeded() }
            }
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<TimelineFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] footer, _, _ in
            footer.onRetry = { self?.onRetry?() }
            self?.configure(footer)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<TimelineHeaderContainerView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] container, _, _ in
            container.host(self?.headerView)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, ItemID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return FrameWork.measure("header.dequeue") { collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath) }
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.main])
        FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
        return dataSource
    }

    private func configure(_ footer: TimelineFooterView) {
        // ヘッダーのある一覧では、投稿がないことも全面の表示ではなくフッターで示す。
        // データソースを作る途中でも呼ばれるため、データソースではなく表示中の要素から数える。
        footer.apply(footerState, reachedEndText: entries.isEmpty ? texts.empty : texts.reachedEnd)
    }

    /// 読めなかった投稿や通知の行。読めなかったことを隠さず、開けるならブラウザで開けることを示す。
    func unreadableContentConfiguration(for item: UnreadableItem, base: UIListContentConfiguration) -> UIListContentConfiguration {
        var content = base
        content.image = UIImage(systemName: "exclamationmark.triangle")
        content.imageProperties.tintColor = .secondaryLabel
        content.text = texts.unreadable
        content.textProperties.color = .secondaryLabel
        content.secondaryText = item.url == nil
            ? "サーバーから届いた内容を読めませんでした。"
            : "サーバーから届いた内容を読めませんでした。タップするとブラウザで開きます。"
        content.secondaryTextProperties.color = .secondaryLabel
        return content
    }

    /// - Parameter failure: 直近の読み込みに失敗した理由。読み込み中なら、読み込み中の表示を優先する。
    func gapContentConfiguration(isLoading: Bool, failure: ErrorPresentation? = nil, base: UIListContentConfiguration) -> UIListContentConfiguration {
        var content = base
        content.textProperties.alignment = .center
        if isLoading {
            content.text = "読み込み中…"
            content.textProperties.color = .secondaryLabel
        } else if let failure {
            // 押すと読み込み直すため、押せることを色で示す。理由は下に小さく添える。
            content.text = "読み込めませんでした。タップして再試行"
            content.textProperties.color = .tintColor
            content.secondaryAttributedText = failure.attributedText(textStyle: .footnote)
            content.secondaryTextProperties.alignment = .center
        } else {
            content.text = "読み込んでいない投稿を読み込む"
            content.textProperties.color = .tintColor
        }
        return content
    }

    /// 投稿のセルの中身を組み立てる。今のチューニングと設定を読むため、使うたびに作る。
    var postContentBuilder: PostContentBuilder {
        PostContentBuilder(tuning: tuning, settings: settings, emojiImages: emojiImages, mediaImages: mediaImages, avatarImages: avatarImages)
    }

    /// - Parameters:
    ///   - isPinned: プロフィールの上に置く、固定された投稿。名前の上に固定されていることを示す行を出す。
    ///   - itemID: この中身を置く行。注意書きを開閉したときに、この行の画面上の位置を保つ。
    func contentConfiguration(for status: Status, isPinned: Bool = false, itemID: ItemID? = nil, base: UIListContentConfiguration) -> PostContentConfiguration {
        let shown = status.displayed
        let connection = itemID.flatMap { replyConnections[$0] } ?? ReplyConnection()
        // スレッドで押した投稿は、開いた時点では返信先がまだ並んでおらずラベルを出しているため、返信先が並んでもラベルを残す。
        // 消すと、読み終えた瞬間に名前と本文がラベルの1行分だけ上へ跳ねる。
        let hidesReplyLabel = hidesReplyLabelBelowParent && connection.parentIsAbove && shown.id != threadFocusID
        let replyLabel = hidesReplyLabel ? nil : ReplyLabel(status: shown, myAccountID: myAccountID)
        var configuration = postContentBuilder.configuration(for: status, isPinned: isPinned, replyLabel: replyLabel, base: base)
        configuration.replyConnection = connection
        configuration.onOpenAccount = { [weak self] in self?.onOpenProfile?(shown.account) }
        configuration.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination, shown) }
        if let itemID {
            configuration.authorTarget = userTarget(for: shown.account, id: itemID)
        }
        if status.reblog != nil, !isPinned {
            configuration.onOpenContextAccount = { [weak self] in self?.onOpenProfile?(status.account) }
            if let itemID {
                configuration.contextTarget = userTarget(for: status.account, id: itemID)
            }
        }
        // フィルターの結果はブーストの外側にだけ付くことがあるため、判定にはブーストごと渡す。
        if let media = mediaContent(for: status) {
            configuration.media = media
            configuration.onSelectMedia = { [weak self] index, grid in
                self?.openMedia(media.attachments, at: index, of: shown, from: grid)
            }
        }
        configuration.onRevealMedia = { [weak self] in
            self?.revealMedia(of: shown)
        }
        configuration.poll = pollContent(for: shown, base: base)
        configuration.onPollAction = { [weak self] action in self?.handlePollAction(action, on: status, keeping: itemID) }
        configuration.card?.coversImage = mediaCovers.linkCardImageCover(for: shown) != nil
        if let itemID, let url = configuration.card?.card.url {
            configuration.linkCardTarget = linkTarget(for: url, id: itemID) { [weak self] in self?.onOpenLink?(.url(url), shown) }
        }
        if let quote = quoteEmbed(for: status, itemID: itemID, base: base) {
            configuration.embed = quote.content
            configuration.embedActions = quote.actions
        } else if let xPost = xPostContent(for: shown, base: base) {
            configuration.embed = xPost.content
            configuration.embedActions.open = { [weak self] _ in self?.onOpenLink?(.url(xPost.url), shown) }
            if let itemID {
                configuration.embedActions.target = externalPostTarget(url: xPost.url, text: xPost.text, id: itemID) { [weak self] in self?.onOpenLink?(.url(xPost.url), shown) }
            }
            configuration.embedActions.selectMedia = { [weak self] index, grid in
                self?.openMedia(xPost.media, at: index, of: shown, from: grid)
            }
            // 投稿した人が付けた閲覧注意でぼかしているため、ぼかしを外すと、投稿の添付ファイルとそろって外れる。
            configuration.embedActions.revealMedia = { [weak self] in self?.revealMedia(of: shown) }
            configuration.embedActions.openLink = { [weak self] destination in self?.onOpenLink?(destination, shown) }
        }
        if case .card(let card)? = configuration.card?.card, let attachment = card.imageAttachment {
            configuration.onOpenLinkCardImage = { [weak self] thumbnail in
                // 開いている間に行が別の投稿に使い回されていたら、その画像へは戻さず、薄くして閉じる。
                self?.openMedia([attachment], at: 0, subject: OperationStatus.Subject(shown)) { [weak thumbnail] _ in
                    thumbnail?.isShowing(attachment.url) == true ? thumbnail : nil
                }
            }
        }
        configuration.spoiler = spoiler(of: status, base: base)
        let ownMatchTitles = filterWarnings.verdict(for: status).ownMatchTitles
        configuration.filterNote = ownMatchTitles.isEmpty ? nil : postContentBuilder.ownFilterNote(titles: ownMatchTitles)
        configuration.onToggleSpoiler = { [weak self] in self?.toggleSpoiler(of: status, keeping: itemID) }
        return configuration
    }

    /// 注意書きの本文を開閉する。フィルターの警告で折りたたんでいれば、注意書きの代わりに警告を開く。同じ投稿をブーストした行と通知の行もまとめて描き直す。
    /// 行の高さが変わるため、押した行の画面上の位置を保つ。同じ投稿の行が上にも並んでいると、その行も伸び縮みするため、
    /// 表示領域の上端の行を基準にすると、押した行がずれる。
    /// - Parameter anchorID: 押した行。なければ、表示領域の上端にかかっている行を基準にする。
    func toggleSpoiler(of status: Status, keeping anchorID: ItemID? = nil) {
        if filterWarnings.verdict(for: status).warningTitles.isEmpty {
            spoilerExpansion.toggle(status)
        } else {
            filterWarnings.reveal(status)
        }
        guard isViewLoaded else { return }
        reconfigure(Set(itemIDs(showing: status)), keeping: anchorID)
    }

    /// `status`を出している行。ブーストした行、通知の行と、引用の囲みに出している行も含める。
    func itemIDs(showing status: Status) -> [ItemID] {
        let shownID = status.displayed.id
        return displayedItemIDs.filter { id in
            guard let displayed = self.status(for: id)?.displayed else { return false }
            return displayed.id == shownID || displayed.quote?.quotedStatus?.id == shownID
        }
    }

    func avatarContent(of account: Account) -> AvatarView.Content {
        postContentBuilder.avatarContent(of: account)
    }

    func body(of status: Status, base: UIListContentConfiguration, color: UIColor = .label) -> NSAttributedString {
        postContentBuilder.body(of: status, base: base, color: color)
    }

    /// 注意書き。開いているかは、この一覧で覚えている状態を当てる。ブーストなら元の投稿の注意書きにする。
    /// フィルターの警告で折りたたんでいれば、注意書きの代わりに警告を出す。警告を開くと、注意書きのある投稿は注意書きで折りたたんだ形に戻る。
    /// - Parameter font: 注意書きの文字の書体。nilなら本文の文字で描く。フィルターの警告には使わない。
    func spoiler(of status: Status, base: UIListContentConfiguration, color: UIColor = .label, font: UIFont? = nil) -> PostBodyContent.Spoiler? {
        let warningTitles = filterWarnings.verdict(for: status).warningTitles
        guard warningTitles.isEmpty else { return postContentBuilder.filterWarning(titles: warningTitles, base: base) }
        var spoiler = postContentBuilder.spoiler(of: status.displayed, base: base, color: color, font: font)
        spoiler?.isCollapsed = spoilerExpansion.isCollapsed(status)
        return spoiler
    }
}

extension TimelineViewController: LinkMenuHost {
    func linkMenuWillShow() {
        UserAction.openMenu(screen: texts.dumpName).record()
        menuWillShow()
        contextMenuIcons.menuWillAppear(in: view.window)
    }

    func linkMenuDidHide() {
        contextMenuIcons.menuWillEnd()
        menuDidHide()
    }

    func showLinkCopiedNotice() {
        showNotice(.linkCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    func showHandleCopiedNotice() {
        showNotice(.handleCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    func openURL(_ url: URL, in browser: LinkBrowser) {
        onOpenURL?(url, browser)
    }

    func openProfile(resolving url: URL) {
        onOpenProfileURL?(url)
    }

    func openHashtag(_ name: String, of account: Account) {
        onOpenAccountHashtag?(name, account)
    }
}

extension TimelineViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        FrameWork.measure("scrollViewDidScroll") { handleScroll(scrollView) }
    }

    private func handleScroll(_ scrollView: UIScrollView) {
        if scrollView.isTracking {
            // 指が下へ動いていれば、内容は上の新しい投稿の方へ動く。
            let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView).y
            if velocity != 0 {
                lastScrollDirection = velocity > 0 ? .towardNewer : .towardOlder
            }
        }
        reportVisibleItems()
        reportApproachingGaps()
        onScroll?(scrollView)
        // 最上部からさらに引っぱっている間は、浮かぶ新着のボタンも一覧と一緒に下げる。上に現れるストリーミングの状態を覆わないようにする。
        // チップの列は下げない。十分に引っぱれば、一番上の投稿とストリーミングの状態が列の下に見えるため。
        let pulled = max(-(scrollView.contentOffset.y + scrollView.adjustedContentInset.top), 0)
        if pulled != pulledDistance {
            pulledDistance = pulled
            newArrivalsButton.transform = CGAffineTransform(translationX: 0, y: pulled)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            recordScroll()
            reportVisibleItemsAfterLayout()
            onInteractionSettle?()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        recordScroll()
        reportVisibleItemsAfterLayout()
        onInteractionSettle?()
    }

    /// 返信先の投稿へ動かしたとき。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportVisibleItemsAfterLayout()
        onInteractionSettle?()
    }

    /// 最上部へ動かしている途中で指が触れたら、そこで止める。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stopSpringScroll()
        // 慣性で動いている途中で触れると、前のスクロールは止まりの通知を受けずに終わるため、ここで記録する。
        recordScroll()
        scrollStart = (scrollView.contentOffset.y, mediaTime())
        scrollHitches.start()
    }

    /// スクロールの途中で新着の挿入などにより位置を補正すると、補正の分も動いた量に入る。
    private func recordScroll() {
        guard let start = scrollStart else { return }
        scrollStart = nil
        let (hitches, work) = scrollHitches.finish()
        FrameWorkLog.record(work, screen: texts.dumpName)
        UserAction.scroll(ScrollRecord(
            screen: texts.dumpName,
            startOffset: start.offset,
            endOffset: collectionView.contentOffset.y,
            viewportHeight: collectionView.bounds.inset(by: collectionView.adjustedContentInset).height,
            duration: mediaTime() - start.time,
            hitches: hitches
        )).record()
    }

    /// 指を離したときの勢いで向きを決め直す。慣性で動く間はこの向きのまま。
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if velocity.y != 0 {
            lastScrollDirection = velocity.y < 0 ? .towardNewer : .towardOlder
        }
    }

    /// ステータスバーのタップ。UIKitに動かさせず、新着ボタンと同じ動きで最上部へ戻る。
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        scrollToNewest()
        UserAction.scrollToTop(screen: texts.dumpName).record()
        return false
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        UserAction.openMenu(screen: texts.dumpName).record()
        menuWillShow()
        contextMenuIcons.menuWillAppear(in: view.window)
    }

    /// メニューが閉じるアニメーションの間も行を動かさない。
    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        contextMenuIcons.menuWillEnd()
        guard let animator else {
            menuDidHide()
            return
        }
        animator.addCompletion { [weak self] in self?.menuDidHide() }
    }

    /// 長押しで投稿への操作のメニューを出す。添付ファイルのサムネイルとリンクカードの画像はボタンで、ここへは届かないため、
    /// それぞれが`MediaMenuHost`に問い合わせてメディアのメニューを出す。
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        // 選んでいる本文の上の長押しは、テキストビューが単語を選ぶのに使う。
        if let body = textSelectionBody, let frame = body.textSelectionFrame, body.convert(frame, to: collectionView).contains(point) { return nil }
        if indexPaths.count == 1, let indexPath = indexPaths.first, rowTarget(at: indexPath)?.performsLongPress() == true { return nil }
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath), let entry = entry(for: id),
              let menu = contextMenu(for: entry, id: id)
        else { return nil }
        // 指の位置にメニューを出せるよう、押した場所をidentifierに持たせる。
        return UIContextMenuConfiguration(identifier: NSValue(cgPoint: point), previewProvider: nil) { _ in menu }
    }

    /// 行を持ち上げず、指の位置の見えない目印をプレビューにして、メニューだけを指の位置に出す。
    /// 行を持ち上げると、閉じるときにガラスのメニューが行の大きさまで広がって吸い込まれ、行の真ん中の文字が波紋のようにゆがむため。
    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        anchorPreview(for: configuration)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        anchorPreview(for: configuration)
    }

    private func anchorPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let point = (configuration.identifier as? NSValue)?.cgPointValue else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UITargetedPreview(view: anchor, parameters: parameters, target: UIPreviewTarget(container: collectionView, center: point))
    }

    /// 選べるのはギャップと、ブラウザで開ける読めなかった要素と、スレッドを開ける投稿と、投稿を含む通知と、人の一覧の人にする。
    /// 本文のリンクや添付ファイルなど、行の中の部品が押下を先に受けるため、投稿の行を選ぶのは、どの部品も受けなかったときだけになる。
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        // 本文を選んでいる間の行のタップは、選ぶのをやめるだけにし、行の操作は行わない。
        if endTextSelection() { return false }
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        return switch (id, entries[id]) {
        case (.gap, _): true
        case (_, .unreadable(let item)): item.url != nil
        // 投稿、通知、人の一覧の行は、タップに選んだ操作を行う。既定の操作が行えない行（スレッドの中心の投稿、投稿のない通知）は、今どおり押せないままにする。
        case (_, .status), (_, .pinned), (_, .notification), (_, .account): rowTarget(at: indexPath)?.acceptsTap ?? false
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        // 本文を選んでいる間は、どの行のタップでも選ぶのをやめられるよう、押せない行でも選ぶ処理まで進める。
        if isSelectingText { return true }
        return self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    private var isSelectingText: Bool {
        textSelectionBody?.isSelectingText == true
    }

    /// `id`の行に出している本文のうち、「テキストを選択」で選べるもの。行が画面にないとき、別の投稿（引用の囲みなど）のメニューのとき、選べないときはnil。
    func selectableBody(for id: ItemID, statusID: Status.ID) -> PostBodyView? {
        guard let indexPath = dataSource.indexPath(for: id), let contentView = collectionView.cellForItem(at: indexPath)?.contentView else { return nil }
        let body = (contentView as? PostContentView)?.postBody ?? (contentView as? NotificationContentView)?.postBody
        guard let body, body.content?.statusID == statusID, body.canSelectText else { return nil }
        return body
    }

    /// 本文を選べる状態にする。ほかの行で選んでいれば、そちらはやめる。メニューを出している間は、閉じ終えてから選ぶ。
    func beginTextSelection(in body: PostBodyView, statusID: Status.ID) {
        if isShowingMenu {
            pendingTextSelection = (body, statusID)
            return
        }
        endTextSelection()
        body.beginTextSelection()
        textSelectionBody = body
    }

    /// 選べる状態の本文があれば、やめる。やめたらtrue。
    @discardableResult
    private func endTextSelection() -> Bool {
        defer { textSelectionBody = nil }
        guard let body = textSelectionBody, body.isSelectingText else { return false }
        body.endTextSelection()
        return true
    }

    /// ギャップは、画面の上半分にあれば下から遡ってきたとみなして古い側から、下半分にあれば新しい側から読む。
    /// どちらも、いま読んでいる側に続く投稿から埋まる。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let target = rowTarget(at: indexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            // キーボードや読み上げのように触れずに選んだときは、前に触れた位置ではなく、選んだ行の真ん中にメニューを出す。
            let touched = touchRecorder.lastLocation.flatMap { collectionView.indexPathForItem(at: $0) == indexPath ? $0 : nil }
            let center = collectionView.layoutAttributesForItem(at: indexPath).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
            target.perform(.tap, in: collectionView, at: touched ?? center)
            return
        }
        if let id = dataSource.itemIdentifier(for: indexPath), case .unreadable(let item) = entries[id], let url = item.url {
            collectionView.deselectItem(at: indexPath, animated: true)
            UIApplication.shared.open(url)
            return
        }
        guard case .gap(let gapID) = dataSource.itemIdentifier(for: indexPath) else { return }
        UserAction.tapGap(screen: texts.dumpName).record()
        collectionView.deselectItem(at: indexPath, animated: true)
        guard !loadingGapIDs.contains(gapID), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        onGapSelect?(gapID, frame.midY < visibleRect.midY ? .fromOlder : .fromNewer)
    }

    /// 投稿のスレッドを開けるか。スレッドの中心の投稿は、開いているスレッドそのものなので開かない。
    func canOpenThread(of status: Status) -> Bool {
        onOpenThread != nil && status.displayed.id != threadFocusID
    }

    /// 要素の行の、ウインドウでの枠。スレッドを開く動きの起点にする。行が画面になければゼロ。
    /// ブーストした人や返信先の行は、スレッドの行には出ないことがあるため、その行を除いた投稿の中身の枠にする。
    func rowFrame(of id: ItemID) -> CGRect {
        guard let indexPath = dataSource.indexPath(for: id), let cell = collectionView.cellForItem(at: indexPath) else { return .zero }
        let context = Self.contextHeight(of: cell)
        return cell.convert(cell.bounds, to: nil).inset(by: UIEdgeInsets(top: context, left: 0, bottom: 0, right: 0))
    }

    private static func contextHeight(of cell: UICollectionViewCell) -> CGFloat {
        (cell.contentView as? PostContentView)?.contextHeight ?? 0
    }

    /// スレッドを開いたことを、違和感レポートの操作の記録に残す。
    func recordOpenThread() {
        UserAction.openThread(screen: texts.dumpName).record()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        let count = dataSource.snapshot().numberOfItems
        if indexPath.item >= count - prefetchThreshold {
            onApproachingEnd?()
        }
    }
}

extension TimelineViewController: UICollectionViewDataSourcePrefetching {
    /// スクロールで画面に入りそうな行のアイコンを読み始める。
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetchAvatars(for: indexPaths.compactMap { dataSource.itemIdentifier(for: $0).flatMap { entries[$0] } })
    }
}

extension TimelineViewController: UIGestureRecognizerDelegate {
    /// 触れて止めたまま、指でスクロールし始められるようにする。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === springScrollInterruption && otherGestureRecognizer === collectionView.panGestureRecognizer
    }
}

// MARK: - スクロール位置の保持

extension TimelineViewController {
    /// 更新の前後で画面上の位置を揃える基準の投稿と、そのセル上端の、表示領域上端からの距離。
    struct ScrollAnchor {
        let id: ItemID
        let distanceFromVisibleTop: CGFloat
    }

    /// 表示領域の上端にかかっている、最も上の投稿を基準にする。
    /// 上端にかかる分が半画素に満たない行は、見えていない行として扱う。行の位置は高さを足し合わせて決まるため、
    /// 上の行の下端が表示領域の上端にぴったり重なるはずのときも、浮動小数点の誤差でわずかに下へずれ、隠れた上の行を基準に選んでしまうため。
    /// - Parameter candidates: 基準にしてよい行。nilなら、見えている行のどれでもよい。
    func currentAnchor(among candidates: Set<ItemID>? = nil) -> ScrollAnchor? {
        collectionView.layoutIfNeeded()
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let halfPixel = 0.5 / max(collectionView.traitCollection.displayScale, 1)
        let topmost = collectionView.indexPathsForVisibleItems
            .compactMap { indexPath -> (ItemID, CGRect)? in
                guard let id = dataSource.itemIdentifier(for: indexPath),
                      candidates?.contains(id) ?? true,
                      let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
                else { return nil }
                return (id, frame)
            }
            .filter { $0.1.maxY > visibleTop + halfPixel }
            .min { $0.1.minY < $1.1.minY }
        guard let (id, frame) = topmost else { return nil }
        return ScrollAnchor(id: id, distanceFromVisibleTop: frame.minY - visibleTop)
    }

    /// `frame`が表示領域の上端`visibleTop`より下に半画素以上かかっていれば、見えていると見なす。
    /// ヘッダーの下端が表示領域の上端にぴったり重なるはずのときも、スクロール位置と上の余白を足し引きする浮動小数点の誤差で、わずかに下へずれるため。
    private func isVisible(_ frame: CGRect, below visibleTop: CGFloat) -> Bool {
        frame.maxY > visibleTop + 0.5 / max(collectionView.traitCollection.displayScale, 1)
    }

    /// ヘッダーの中身が変わって高さが変わったときに呼ぶ。ヘッダーを読み終えて下の投稿を読んでいれば、その投稿の位置を変えない。
    /// ヘッダーが見えていれば、ヘッダーが伸び縮みした分だけ下の投稿が動くのに任せる。
    /// 画面を読み込む前は、最初の表示で測るため何もしない。
    func headerDidChangeSize() {
        guard headerView != nil, isViewLoaded, dataSource.snapshot().numberOfSections > 0 else { return }
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        collectionView.layoutIfNeeded()
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let headerFrame = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: 0)
        )?.frame
        let anchor = (headerFrame.map { !isVisible($0, below: visibleTop) } ?? false) ? currentAnchor() : nil
        if let anchor {
            collectionView.collectionViewLayout.invalidateLayout()
            restore(anchor)
        } else {
            // ヘッダーが見えている間は、ヘッダーを動かさず、伸び縮みした分だけ下の行を動かす。
            // 作り直したレイアウトでは、ヘッダーの高さが見積もり（28pt）に戻り、その高さで画面に入るときだけ測り直される。
            // ヘッダーの上端が画面の上の外にあると、見積もりのまま画面外と見なされ、ヘッダーが消える。
            // そのため、作り直す間だけ一番上へ移して測らせ、同じフレームの中で元の位置へ戻す。
            let offset = collectionView.contentOffset.y
            let top = -collectionView.adjustedContentInset.top
            collectionView.contentOffset.y = top
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            let bottom = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height
            // 一番上から引っぱっている間（上端より上）は、引っぱった分をそのまま戻す。上端に詰めると、指を離す前にヘッダーが跳ぶ。
            collectionView.contentOffset.y = offset < top ? offset : min(offset, max(bottom, top))
            collectionView.layoutIfNeeded()
        }
    }

    /// ヘッダーの中身が変わって伸び縮みした分を、ヘッダーの下の内容と下の行ごとスプリングで動かしてつなぐ。動きの途中も操作を受け付ける。
    /// ヘッダーを読み終えて下の行を読んでいるときと、`duration`が0のときは、動かさずに`headerDidChangeSize()`と同じく位置を保つ。
    func headerDidChangeSize(animatingWithDuration duration: TimeInterval) {
        guard duration > 0, view.window != nil, headerView != nil, dataSource.snapshot().numberOfSections > 0 else {
            headerDidChangeSize()
            return
        }
        let header = IndexPath(item: 0, section: 0)
        // ここで並べ直すと、伸びた中身を前の高さのヘッダーに押し込んだ形が、動きの出発点になってしまう。並べ直すのは動きの中だけにする。
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        guard let headerFrame = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: header)?.frame,
              isVisible(headerFrame, below: visibleTop)
        else {
            headerDidChangeSize()
            return
        }
        let offset = collectionView.contentOffset.y
        UIView.animate(springDuration: duration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            let context = UICollectionViewLayoutInvalidationContext()
            context.invalidateSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader, at: [header])
            self.collectionView.collectionViewLayout.invalidateLayout(with: context)
            self.collectionView.layoutIfNeeded()
            // ヘッダーの上端が表示領域の上端より上にあると、一覧は下の行の位置を保とうとして、伸びた分だけスクロール位置を足す。
            // それではヘッダーが上へ伸びて見えるため、`headerDidChangeSize()`と同じく、ヘッダーを動かさず下の行を動かす位置に戻す。
            let top = -self.collectionView.adjustedContentInset.top
            let bottom = self.collectionView.contentSize.height + self.collectionView.adjustedContentInset.bottom - self.collectionView.bounds.height
            self.collectionView.contentOffset.y = offset < top ? offset : min(offset, max(bottom, top))
        }
    }

    /// 画面に出るときに、`id`の行の上端を、ウインドウの`windowY`の高さに置く。スレッドを、押した行を一覧で見えていた位置に置いて開くのに使う。
    /// 画面に出るまでは、安全領域とバーの高さが分からないため、出るときに置く。
    func placeOnAppearing(_ id: ItemID, atWindowY windowY: CGFloat) {
        pendingOpening = (id, windowY)
    }

    /// 開いた時点では押した行の上に並ぶ行がないため、上の余白を足して、押した行を押した位置まで下げる。
    private func applyPendingOpening() {
        guard let opening = pendingOpening, let window = view.window else { return }
        pendingOpening = nil
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: opening.id),
              var frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return }
        // 押した行と同じく、ブーストした人や返信先の行を除いた投稿の中身の上端を、押した位置に合わせる。
        // 一覧ではブーストの行でも、スレッドではブーストした人の行がないため、行の上端で合わせると中身が1行分ずれて重なって見える。
        if let cell = collectionView.cellForItem(at: indexPath) {
            frame.origin.y += Self.contextHeight(of: cell)
        }
        let rowTopInView = frame.minY - collectionView.contentOffset.y
        let targetInView = collectionView.convert(CGPoint(x: 0, y: opening.windowY), from: window).y - collectionView.contentOffset.y
        // 押した行の上端がバーの下に隠れていたときは、余白は足さず、同じだけ隠れた位置に置く。
        let extra = max(targetInView - rowTopInView, 0)
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        openingInset = extra
        collectionView.contentInset.top += extra
        updateObscuredBottomInset()
        // 余白を足すと、最上部にいる一覧はUIKitが位置を合わせ直すため、ずらす量ではなく位置そのものを置く。
        collectionView.contentOffset.y = frame.minY - targetInView
    }

    /// 開くときに足した上の余白を、上に並んだ行で置き換える。上に並んだ行が余白より低いときは、最上部までスプリングで動かして詰める。
    func releaseOpeningInset() {
        guard openingInset > 0 else { return }
        let offset = collectionView.contentOffset.y
        isRestoringAnchor = true
        // 余白を変えると、UIKitが位置を合わせ直すことがあるため、変える前の位置に置き直す。
        collectionView.contentInset.top -= openingInset
        openingInset = 0
        updateObscuredBottomInset()
        collectionView.contentOffset.y = offset
        isRestoringAnchor = false
        if offset < topOffset {
            scrollToTop(
                duration: tuning.value(of: TuningCatalog.insertionScrollDuration),
                bounce: tuning.value(of: TuningCatalog.insertionScrollBounce)
            )
        }
    }

    /// `id`の行のすぐ下の行が表示領域の下端より下にあれば、`id`の行を表示領域の上端まで動かし、下の行を見せる。
    func raiseIfNextRowHidden(_ id: ItemID) {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return }
        let next = IndexPath(item: indexPath.item + 1, section: indexPath.section)
        guard next.item < collectionView.numberOfItems(inSection: indexPath.section),
              let nextFrame = collectionView.layoutAttributesForItem(at: next)?.frame
        else { return }
        let inset = collectionView.adjustedContentInset
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - inset.bottom
        guard nextFrame.minY >= visibleBottom else { return }
        let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: min(frame.minY - inset.top, maxOffset)), animated: true)
    }

    /// 要素のセル上端を表示領域の上端に合わせる。下に十分な要素がなければ、末尾までスクロールしたところで止める。
    private func scrollToTop(of id: ItemID) {
        restore(ScrollAnchor(id: id, distanceFromVisibleTop: 0))
        let inset = collectionView.adjustedContentInset
        let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
        if collectionView.contentOffset.y > maxOffset {
            collectionView.contentOffset.y = maxOffset
        }
    }

    /// 表示領域の外にあっても、指定した要素を基準にする。
    func anchor(of id: ItemID) -> ScrollAnchor? {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return nil }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return ScrollAnchor(id: id, distanceFromVisibleTop: frame.minY - visibleTop)
    }

    /// スナップショットを当て、更新前の基準の要素を同じ位置に戻す。戻した基準を返す。
    /// `anchorID`がなければ、表示領域の上端にあった要素を基準にする。
    @discardableResult
    private func applyPreservingAnchor(_ snapshot: NSDiffableDataSourceSnapshot<Section, ItemID>, keeping anchorID: ItemID? = nil) -> ScrollAnchor? {
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        // 表示領域の上端にかかっている行が消えるときは、残る行のうち一番上に見えている行を基準にする。
        // 消える行を基準にすると、当て直したあとに位置を合わせる行がなく、読んでいる行が流れるため。
        let anchor = anchorID.flatMap(anchor(of:)) ?? currentAnchor(among: Set(snapshot.itemIdentifiers))
        FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
        if let anchor {
            restore(anchor)
        }
        return anchor
    }

    /// contentOffsetを動かすと、新たに表示されたセルが推定サイズから実サイズへ変わり、基準の位置がまたずれる。
    /// そのため、基準の位置が変わらなくなるまで補正を繰り返す。
    private func restore(_ anchor: ScrollAnchor) {
        for _ in 0..<8 {
            collectionView.layoutIfNeeded()
            guard let indexPath = dataSource.indexPath(for: anchor.id),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { return }
            let target = frame.minY - anchor.distanceFromVisibleTop - collectionView.adjustedContentInset.top
            if abs(collectionView.contentOffset.y - target) < 0.01 { return }
            collectionView.contentOffset.y = target
        }
    }
}

extension TimelineViewController: NoticeScreen {
    /// チップの列の上端。この画面の座標。ナビゲーションバーの下に置く。一番上から引っぱっても下げない。
    /// 新着のボタンが出ていてもずらさず、上に重ねる。ボタンは件数の目安で、隠れてもステータスバーやタブから最上部へ戻れるが、
    /// 出たままのチップは、押そうとしている間にボタンの出入りで動くと押せなくなるため。
    var noticeTop: CGFloat {
        view.safeAreaInsets.top + 8
    }

    func noticePlacement(below: CGFloat) -> NoticePlacement {
        NoticePlacement(top: view.convert(CGPoint(x: 0, y: noticeTop), to: nil).y)
    }
}

/// タイムラインの一覧。本文のリンクを押して少し止めてから引いても、スクロールできるようにする。
final class TimelineCollectionView: UICollectionView {
    override func layoutSubviews() {
        FrameWork.measure("TimelineCollectionView.layoutSubviews") { super.layoutSubviews() }
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is LinkHitArea || super.touchesShouldCancel(in: view)
    }
}

extension TimelineViewController: MediaMenuHost {
    /// サムネイルかリンクカードの画像を長押しした。行の要素を探して、メディアのメニューを組む。投稿のメニューは、その「投稿」に入れる。
    func mediaMenu(from view: UIView, at location: CGPoint, groups: MenuLayout<MediaMenuItem>.Groups?) -> UIMenu? {
        var cellView = view.superview
        while let current = cellView, !(current is UICollectionViewCell) {
            cellView = current.superview
        }
        guard let cell = cellView as? UICollectionViewCell, let indexPath = collectionView.indexPath(for: cell),
              let id = dataSource.itemIdentifier(for: indexPath), let entry = entry(for: id),
              let target = mediaMenuTarget(at: view.convert(location, to: collectionView), in: cell)
        else { return nil }
        return mediaMenu(for: target, entry: entry, id: id, groups: groups)
    }

    func mediaMenuWillShow() {
        UserAction.openMenu(screen: texts.dumpName).record()
        menuWillShow()
    }

    func mediaMenuDidHide() {
        menuDidHide()
    }
}
