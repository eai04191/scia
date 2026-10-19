import os
import SciaCore
import UIKit

/// タイムライン表示。スクロール位置の制御を細かく行うため、UICollectionViewとdiffable data sourceで組む。
final class TimelineViewController: UIViewController {
    private enum Section { case main }
    typealias ItemID = TimelineEntry.ID

    private let logger = SciaLog.logger(category: "timeline")

    /// 一覧ごとに変わる文言。
    struct Texts {
        /// 違和感レポートの状態ダンプに使う名前。
        let dumpName: String
        let title: String
        /// 1件もないとき。
        let empty: String
        /// これより古いものがないとき。
        let reachedEnd: String
        /// サーバーから届いたが、読めなかった要素の行。
        let unreadable: String

        static let home = Texts(dumpName: "timeline", title: "ホーム", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
        static let notifications = Texts(dumpName: "notifications", title: "通知", empty: "通知はありません", reachedEnd: "これより前の通知はありません", unreadable: "表示できない通知")
        static let profile = Texts(dumpName: "profile", title: "", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
    }

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
    /// アプリ内のSafariのシートを出している間だけ右上に出す、投稿欄で書き始めるボタンが押されたときに呼ぶ。
    /// シートを出している間は投稿欄がシートの裏に隠れて触れないため、その入口にする。
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
    /// 投稿のアイコンや名前がタップされたとき、または長押しのメニューで選ばれたときに、そのアカウントを渡して呼ぶ。
    var onOpenProfile: ((Account) -> Void)?
    /// アカウントの全体を持たない相手（メンション）のプロフィールを、IDで開く。
    var onOpenProfileID: ((String) -> Void)?
    /// 投稿の本文のリンクがタップされたときに、行き先と、本文を描いた投稿（ブーストなら元の投稿）を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination, Status) -> Void)?
    /// 長押しのメニューの開く項目で、開く場所を決めてURLを開く。
    var onOpenURL: ((URL, LinkBrowser) -> Void)?
    /// この画面が表示されている間、生かしておくもの。画面を組み立てたコントローラーを、ナビゲーションから外されるまで残すのに使う。
    var lifetimeOwner: AnyObject?
    /// 一覧の頭に置き、一緒にスクロールするビュー。プロフィールのヘッダーに使う。表示より前に設定する。
    /// 置くと、投稿がないときの全面の表示は出さず、読み込みの状態はフッターだけで示す。ヘッダーを覆わないようにするため。
    var headerView: UIView?
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
    private var loadingGapIDs: Set<String> = []
    /// 直近の読み込みに失敗したギャップと、その理由。行の中で読めなかったことを知らせる。
    private var gapFailures: [String: ErrorPresentation] = [:]
    private var isShowingMenu = false
    /// メニューを出している間に届いた並びの更新。閉じたときに反映する。
    private var heldEntries: HeldEntries?
    /// メニューを出している間に求められた描き直し。
    private var heldReconfigureIDs: Set<ItemID> = []
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
    /// 最上部へばねで動かしている間、毎フレーム経過時間を渡すもの。
    private var topScrollTicker: FrameTicker?
    /// 最上部へ動かしている間の、ばねの位置の進め方と今の速さ。
    private var topScroll: SpringScroll?
    /// 最上部へ動かしている間だけ有効にし、指が触れた時点で止める。触れたタッチは中身に渡さない。
    /// UIKitのスクロールと同じく、動いている一覧に触れて止めたつもりで、指の下の画像やリンクが開かないようにするため。
    private lazy var scrollToTopInterruption = makeScrollToTopInterruption()
    /// 指で動かしているスクロールの始まり。止まったら違和感レポート用に記録する。
    private var scrollStart: (offset: CGFloat, time: CFTimeInterval)?
    private let scrollHitches = ScrollHitchMonitor()
    private lazy var newArrivalsButton = makeNewArrivalsButton()
    /// 一覧の最上部から引っぱって、浮かべた新着のボタンを下げている量。
    private var pulledDistance: CGFloat = 0
    /// アプリ全体のアプリ内通知。お気に入りやブーストの失敗、リンクのコピーを出す。セッションが入れる。
    var notices: NoticeCenter?
    /// 添付ファイルのビューアで、共有や保存のために落とす処理。ビューアを閉じても続けるため、セッションで持つ。
    var mediaTransfers: MediaTransferCenter?
    private var timeRefreshTimer: Timer?
    private let texts: Texts
    let tuning: TuningStore
    let emojiImages: EmojiImageStore
    let mediaImages: MediaImageStore
    let avatarImages: AvatarImageStore
    let network: NetworkConditionsMonitor
    let settings: AppSettings
    /// 添付ファイルを覆うか。閲覧注意の覆いを外した投稿と、メニューから隠した投稿を覚える。セッションがほかの画面とそろえる。
    var mediaCovers = MediaCovers()
    /// この画面で開いたり隠したりしたときに、変えたあとの状態と、変えた投稿を渡して呼ぶ。
    var onChangeMediaCovers: ((MediaCovers, Status) -> Void)?
    /// fxtwitterから読んだXの投稿。セッションの中で1つを共有する。
    var xPosts: XPostStore?
    /// この一覧で当てるサーバーのフィルターと、警告で畳んだ投稿のうち開いたもの。一覧を持つ側が、一覧の場所に合わせて入れる。
    var filterWarnings = FilterWarnings()
    /// 注意書きのある投稿の本文を開いているか。サーバーの設定が読めたら、セッションが既定を入れる。
    var spoilerExpansion = SpoilerExpansion() {
        didSet {
            guard spoilerExpansion.expandsByDefault != oldValue.expandsByDefault, isViewLoaded else { return }
            reconfigure(Set(displayedItemIDs.filter { status(for: $0)?.displayed.spoilerText.isEmpty == false }))
        }
    }

    init(
        texts: Texts = .home,
        tuning: TuningStore = AppDependencies.tuning,
        emojiImages: EmojiImageStore = AppDependencies.emojiImages,
        mediaImages: MediaImageStore = AppDependencies.mediaImages,
        avatarImages: AvatarImageStore = AppDependencies.avatarImages,
        network: NetworkConditionsMonitor = AppDependencies.network,
        settings: AppSettings = AppDependencies.settings
    ) {
        self.texts = texts
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

    /// アプリ内のSafariのシートを出している間だけ、右上に投稿欄で書き始めるボタンを出す。画面を読み込む前は値だけ覚える。
    func setShowsFocusInlineCompose(_ shows: Bool) {
        guard showsFocusInlineCompose != shows else { return }
        showsFocusInlineCompose = shows
        if isViewLoaded { applyBarItems() }
    }

    /// `rightBarButtonItems`は右から並ぶため、先頭に足したボタンがいちばん右に来る。
    private func applyBarItems() {
        navigationItem.rightBarButtonItems = (showsFocusInlineCompose && onFocusInlineCompose != nil ? [focusInlineComposeItem] : []) + baseBarItems
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if !texts.title.isEmpty {
            title = texts.title
        }
        #if DEBUG
        baseBarItems = [makeDebugMenuButton(screenActions: debugActions, faults: onDebugURL.map { DebugFaultMenu.make(handle: $0) }, handle: onDebugURL)]
        #endif
        applyBarItems()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.hidesTopEdgeEffectOnMac()
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.addGestureRecognizer(scrollToTopInterruption)
        // タブバーの上の投稿欄で書いている間も、読み進めるだけならキーボードを閉じない。キーボードまで引き下ろしたら閉じる。
        collectionView.keyboardDismissMode = .interactive
        view.addSubview(collectionView)
        // 新着のボタンは、この一覧の部品として画面と一緒に流れる。チップの列はウインドウに重ね、このボタンの下に置く。
        view.addSubview(newArrivalsButton)
        NSLayoutConstraint.activate([
            newArrivalsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            newArrivalsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newArrivalsButton.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
        ])
        AppDependencies.stateDumps.register(texts.dumpName, owner: self) { $0.stateDump() }
        emojiImages.addListener(owner: self) { [weak self] urls in self?.emojiImagesDidLoad(urls) }
        avatarImages.addListener(owner: self) { [weak self] key in self?.avatarImageDidLoad(key) }
        observeTuning()
    }

    /// 安全領域やナビゲーションバーの高さが変わったら、チップの列を置き直す。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        noticeOverlay?.update()
    }

    /// 他のタブにいる間に表示が変わっても既読にしないため、画面に出たときに改めて報告する。
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timeRefreshTimer?.invalidate()
        timeRefreshTimer = nil
        onVisibleLinkOnlyCardsChange?([])
    }

    /// 相対表記の時刻を、表示中の行だけ1秒ごとに書き直す。行の高さは変わらないため、並びは描き直さない。
    private func startRefreshingTimes() {
        timeRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleTimes() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        timeRefreshTimer = timer
    }

    private func refreshVisibleTimes() {
        guard settings.statusTimeStyle == .relative else { return }
        let now = Date.now
        for cell in collectionView.visibleCells {
            (cell.contentView as? PostContentView)?.refreshTime(now: now)
        }
    }

    /// チューニングの値、回線の状態、設定が変わったら、表示中の投稿を描き直す。
    /// サムネイルは、低データモードを抜けたときなどに、表示中のものも読む画像を選び直す。
    private func observeTuning() {
        withObservationTracking {
            _ = tuning.value(of: TuningCatalog.paragraphSpacing)
            _ = tuning.value(of: TuningCatalog.mediaTallestAspectRatio)
            _ = tuning.value(of: TuningCatalog.mediaThumbnailUpscaleTolerance)
            _ = tuning.value(of: TuningCatalog.avatarSize)
            _ = tuning.value(of: TuningCatalog.boosterAvatarSize)
            _ = tuning.value(of: TuningCatalog.nameFadeWidth)
            _ = tuning.value(of: TuningCatalog.contextSymbolSpacing)
            _ = tuning.value(of: TuningCatalog.avatarSpacing)
            _ = tuning.value(of: TuningCatalog.contextSpacing)
            _ = tuning.value(of: TuningCatalog.nameBodySpacing)
            _ = tuning.value(of: TuningCatalog.bodyMediaSpacing)
            _ = tuning.value(of: TuningCatalog.nameMediaSpacing)
            _ = tuning.value(of: TuningCatalog.bodyLinkCardSpacing)
            _ = tuning.value(of: TuningCatalog.linkCardPadding)
            _ = tuning.value(of: TuningCatalog.xPostEmbeds)
            _ = tuning.value(of: TuningCatalog.xPostAvatarSize)
            _ = tuning.value(of: TuningCatalog.spoilerPadding)
            _ = tuning.value(of: TuningCatalog.spoilerBodySpacing)
            _ = tuning.value(of: TuningCatalog.mediaTileSpacing)
            _ = tuning.value(of: TuningCatalog.notificationQuotedMediaSpacing)
            _ = tuning.value(of: TuningCatalog.notificationHeaderDetailSpacing)
            _ = tuning.value(of: TuningCatalog.notificationQuotedSpacing)
            _ = tuning.value(of: TuningCatalog.notificationQuotedBodyLines)
            _ = tuning.value(of: TuningCatalog.notificationQuotedThumbnailSize)
            _ = network.conditions
            _ = settings.usesOriginalThumbnailsOnExpensiveNetwork
            _ = settings.ignoresUselessAltText
            _ = settings.statusNameStyle
            _ = settings.statusTimeStyle
            _ = settings.avatarShape
            _ = settings.animatesAvatars
            _ = settings.linkCardThumbnailSide
            _ = settings.glyphLanguage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconfigure(Set(self.dataSource.snapshot().itemIdentifiers))
                self.observeTuning()
            }
        }
    }

    /// 絵文字の画像が届いたら、その絵文字を使う投稿だけを描き直す。
    private func emojiImagesDidLoad(_ urls: Set<URL>) {
        let ids = dataSource.snapshot().itemIdentifiers.filter { id in
            switch entries[id] {
            case .status(let status), .pinned(let status): !Self.emojiURLs(of: status).isDisjoint(with: urls)
            case .notification(let notification): !Self.emojiURLs(of: notification).isDisjoint(with: urls)
            case .gap, .unreadable, nil: false
            }
        }
        reconfigure(Set(ids))
    }

    /// 通知のアイコンは文字に差し込んでいるため、届いたらその人からの通知を描き直す。投稿のアイコンはビューが自分で受け取る。
    private func avatarImageDidLoad(_ key: AvatarImageStore.Key) {
        let ids = dataSource.snapshot().itemIdentifiers.filter { id in
            guard case .notification(let notification) = entries[id] else { return false }
            return avatarContent(of: notification.account).url == key.url
        }
        reconfigure(Set(ids))
    }

    private static func emojiURLs(of status: Status) -> Set<URL> {
        let shown = status.displayed
        return Set((shown.emojis + shown.account.emojis + status.account.emojis).map(\.staticUrl))
    }

    private static func emojiURLs(of notification: MastodonNotification) -> Set<URL> {
        Set(notification.account.emojis.map(\.staticUrl)).union(notification.status.map(emojiURLs(of:)) ?? [])
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
    /// 上端が表示領域の上端より上にある行は、伸びると読んでいる位置がずれるため、動かさずに位置を保って描き直す。
    /// 画面に出ていない行と、メニューを出している間も、動かさずに描き直す。
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
        reconfigure(others)
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
    /// ただし最上部にいて追従が有効なら、最上部に留まって新着を見せる。
    /// `topID`を渡すと、その要素を表示領域の上端に置く。既読位置から読み始めるときに使う。
    /// - Parameter keepsOffset: 一覧の中身を取り替える。要素を基準にせず、スクロール位置をそのまま保つ。
    ///   プロフィールのタブの切り替えのように、ヘッダーを押した場所に残し、その下の中身だけを入れ替えたいときに使う。
    ///   新しい一覧が短くていまの位置までスクロールできなければ、末尾までスクロールしたところで止める。
    func setEntries(_ newEntries: [TimelineEntry], keeping anchorID: ItemID? = nil, placingAtTop topID: ItemID? = nil, keepsOffset: Bool = false) {
        guard !isShowingMenu else {
            // 後の呼び出しの並びが新しい。基準は、メニューが閉じたときに最後に指定されたものを使う。
            heldEntries = HeldEntries(
                entries: newEntries,
                anchorID: anchorID ?? heldEntries?.anchorID,
                topID: topID ?? heldEntries?.topID,
                keepsOffset: keepsOffset || (heldEntries?.keepsOffset ?? false)
            )
            return
        }
        let previous = entries
        let followsTop = anchorID == nil && topID == nil && isAtTop && tuning.value(of: TuningCatalog.followsNewArrivalsAtTop)
        entries = Dictionary(newEntries.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        gapIDs = newEntries.compactMap { entry in
            if case .gap(let gap) = entry { gap.id } else { nil }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newEntries.map(\.id))
        // 差分はIDで取られるため、同じIDのまま内容が変わった要素は明示的にセルを再構成する。
        let changedIDs = newEntries.filter { entry in previous[entry.id].map { $0 != entry } ?? false }.map(\.id)
        snapshot.reconfigureItems(Array(Set(changedIDs)))
        if let topID {
            isRestoringAnchor = true
            dataSource.apply(snapshot, animatingDifferences: false)
            scrollToTop(of: topID)
            isRestoringAnchor = false
            logger.info("setEntries count=\(newEntries.count, privacy: .public) top=\(Self.label(topID), privacy: .public)")
        } else if keepsOffset {
            isRestoringAnchor = true
            let offset = collectionView.contentOffset.y
            dataSource.apply(snapshot, animatingDifferences: false)
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
                dataSource.apply(snapshot, animatingDifferences: false)
                collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
                isRestoringAnchor = false
            }
            logger.info("setEntries count=\(newEntries.count, privacy: .public) followsTop=true animated=\(animates, privacy: .public)")
        } else {
            let anchor = applyPreservingAnchor(snapshot, keeping: anchorID)
            logger.info("setEntries count=\(newEntries.count, privacy: .public) anchor=\(anchor.map { Self.label($0.id) } ?? "nil", privacy: .public)")
        }
        setNeedsUpdateContentUnavailableConfiguration()
        reportVisibleItems()
        reportApproachingGaps()
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

    private struct HeldEntries {
        let entries: [TimelineEntry]
        let anchorID: ItemID?
        let topID: ItemID?
        let keepsOffset: Bool
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
            setEntries(held.entries, keeping: held.anchorID, placingAtTop: held.topID, keepsOffset: held.keepsOffset)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let reconfigureIDs = heldReconfigureIDs.intersection(existing)
        heldReconfigureIDs.removeAll()
        reconfigure(reconfigureIDs)
        onInteractionSettle?()
    }

    /// 既読より新しい投稿の数。0なら新着ボタンを隠す。
    /// - Parameter isLowerBound: 未読の区間に読み込んでいない投稿があり、実際はもっと多い。
    func setUnreadCount(_ count: Int, isLowerBound: Bool = false) {
        unreadCount = count
        updateNewArrivalsButtonVisibility()
        newArrivalsButton.configuration?.title = isLowerBound ? "\(count)件以上の新着" : "\(count)件の新着"
    }

    /// 最上部へ動かしている間は隠す。新着を足して最上部へ動かすときに、新着が画面に入るまでの間だけ出てしまうため。
    private func updateNewArrivalsButtonVisibility() {
        let isHidden = unreadCount == 0 || isScrollingToTop
        guard newArrivalsButton.isHidden != isHidden else { return }
        newArrivalsButton.isHidden = isHidden
        // ボタンの出入りそのものは動かさずに切り替わるため、チップの列だけを前の位置から動かす。
        noticeOverlay?.update(.animated(tuning.value(of: TuningCatalog.noticeAnimationDuration)))
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

    /// ストリーミングにつながらない状態が続いていることを、タイトルの下に控えめに出す。
    func setOutageNotice(_ isShown: Bool) {
        navigationItem.subtitle = isShown ? "ストリーミング切断中" : nil
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

    /// 要素の行。画面の外にあればnil。
    func cell(for id: ItemID) -> UICollectionViewCell? {
        dataSource.indexPath(for: id).flatMap(collectionView.cellForItem(at:))
    }

    private func makeNewArrivalsButton() -> UIButton {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "arrow.up")
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            // 慣性で動いている途中なら、それまでのスクロールが先に記録されるよう、動かしてから記録する。
            scrollToNewest()
            UserAction.tapNewArrivals(screen: texts.dumpName).record()
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }

    /// 投稿が一覧にあれば、覆われていない表示領域の下端に来るまでスクロールする。返信先の札から、書いている入力欄のすぐ上に返信先を出すために使う。
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
            case .gap, .unreadable, nil: false
            }
        }
        let found = chosen ?? ids.first { id in
            switch entries[id] {
            case .status(let status), .pinned(let status): status.displayed.id == displayedID
            case .notification(let notification): notification.status?.displayed.id == displayedID
            case .gap, .unreadable, nil: false
            }
        }
        guard let found, let indexPath = dataSource.indexPath(for: found) else { return false }
        // 最上部へ動かしている途中なら、それをやめる。続けると、返信先へ動かす位置と取り合う。
        stopScrollingToTop()
        collectionView.scrollToItem(at: indexPath, at: position, animated: animated)
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
    /// 覆いを外したときに末尾が下端に合わせて下がる。末尾は古い投稿を読み込む途中で留まる場所ではなく、そこで書き始めることはまれなため、補正しない。
    func setObscuredBottomHeight(_ height: CGFloat) {
        obscuredBottomHeight = height
        updateObscuredBottomInset()
    }

    /// タブバーや投稿欄のアクセサリーの分はsafe areaに入っているため、それを超えて覆っている分だけ足す。
    /// 画面を読み込む前は値だけを覚え、読み込んだあとのsafe areaの変化で反映する。ここで読み込むと、画面を組み立てる前に置くボタンなどの設定より先に読み込まれてしまう。
    private func updateObscuredBottomInset() {
        guard isViewLoaded else { return }
        let inset = max(0, obscuredBottomHeight - view.safeAreaInsets.bottom)
        guard collectionView.contentInset.bottom != inset else { return }
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
        reportVisibleItems()
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

    /// 最上部へばねで動かす。UIKitのスクロールのアニメーションは時間も曲線も変えられないため、毎フレーム位置を置く。
    ///
    /// 上のセルは表示されたときに見積もりから実寸へ変わり、UICollectionViewがそのぶん位置を補正する。
    /// 動いている途中に新着を足したときも、読んでいる位置を保つためにずらす。どちらも、ずれた位置から速さを持ち越して
    /// 最上部へ向かうため、中身は飛ばず、止まり直しもしない。すでに動かしていれば、速さを持ち越して時間と弾みだけ替える。
    /// 動いている途中に指が触れたら止め、指の操作に任せる。
    private func scrollToTop(duration: TimeInterval, bounce: Double) {
        topScroll = SpringScroll(duration: duration, bounce: bounce, velocity: topScroll?.velocity ?? 0)
        guard topScrollTicker == nil else { return }
        // 慣性で動いている途中なら止める。止めないと、慣性で動かす位置と取り合う。
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        // 動いている途中にこの画面が閉じられて解放されたら、続けないと返して止めさせる。
        let ticker = FrameTicker { [weak self] elapsed in
            guard let self else { return false }
            stepScrollingToTop(elapsed: elapsed)
            return isScrollingToTop
        }
        topScrollTicker = ticker
        scrollToTopInterruption.isEnabled = true
        ticker.start()
        updateNewArrivalsButtonVisibility()
    }

    /// 最上部にいるときのスクロール位置。
    private var topOffset: CGFloat {
        -collectionView.adjustedContentInset.top
    }

    private func stepScrollingToTop(elapsed: CFTimeInterval) {
        // 指が触れた時点で止める。ドラッグが始まるのを待つと、触れてから指が動くまでの間も動き続け、指の下で中身がずれる。
        guard !collectionView.isTracking, var scroll = topScroll else {
            stopScrollingToTop()
            return
        }
        let target = topOffset
        let next = scroll.step(from: collectionView.contentOffset.y, toward: target, by: elapsed)
        topScroll = scroll
        guard !scroll.isSettled(at: next, target: target) else {
            didFinishScrollingToTop()
            return
        }
        collectionView.contentOffset.y = next
    }

    /// 落ち着いたら最上部にそろえる。新着ボタンは、見えた投稿を既読にしてから出し直す。先に出すと、既読になるまでの一瞬だけ出てしまう。
    private func didFinishScrollingToTop() {
        endScrollingToTop()
        collectionView.contentOffset.y = topOffset
        reportVisibleItemsAfterLayout()
        updateNewArrivalsButtonVisibility()
        onInteractionSettle?()
    }

    private func stopScrollingToTop() {
        endScrollingToTop()
        updateNewArrivalsButtonVisibility()
    }

    private func endScrollingToTop() {
        topScrollTicker?.stop()
        topScrollTicker = nil
        topScroll = nil
        scrollToTopInterruption.isEnabled = false
    }

    /// 最上部へばねで動かしている。
    var isScrollingToTop: Bool {
        topScrollTicker != nil
    }

    private func makeScrollToTopInterruption() -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(interruptScrollingToTop(_:)))
        recognizer.minimumPressDuration = 0
        recognizer.isEnabled = false
        recognizer.delegate = self
        return recognizer
    }

    @objc private func interruptScrollingToTop(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        stopScrollingToTop()
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
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            // plainのリストはフッターを表示範囲の下端に貼り付ける。貼り付いたフッターは、中身がなくてもタブバーのすぐ上を覆ってタップを吸うため、一覧の末尾に置く。
            for item in section.boundarySupplementaryItems {
                item.pinToVisibleBounds = false
            }
            return section
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, ItemID> {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemID> { [weak self] cell, _, id in
            guard let self, let entry = self.entries[id] else { return }
            cell.accessories = Self.interactionAccessories(for: self.status(for: id))
            switch entry {
            case .status(let status):
                cell.contentConfiguration = self.contentConfiguration(for: status, itemID: id, base: cell.defaultContentConfiguration())
            case .pinned(let status):
                cell.contentConfiguration = self.contentConfiguration(for: status, isPinned: true, itemID: id, base: cell.defaultContentConfiguration())
            case .gap(let gap):
                cell.contentConfiguration = self.gapContentConfiguration(
                    isLoading: self.loadingGapIDs.contains(gap.id),
                    failure: self.gapFailures[gap.id],
                    base: cell.defaultContentConfiguration()
                )
            case .notification(let notification):
                cell.contentConfiguration = self.contentConfiguration(for: notification, itemID: id, base: cell.defaultContentConfiguration())
            case .unreadable(let item):
                cell.contentConfiguration = self.unreadableContentConfiguration(for: item, base: cell.defaultContentConfiguration())
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
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
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
        var configuration = postContentBuilder.configuration(for: status, isPinned: isPinned, base: base)
        configuration.onOpenAccount = { [weak self] in self?.onOpenProfile?(shown.account) }
        configuration.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination, shown) }
        if status.reblog != nil, !isPinned {
            configuration.onOpenContextAccount = { [weak self] in self?.onOpenProfile?(status.account) }
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
        configuration.card?.coversImage = mediaCovers.linkCardImageCover(for: shown) != nil
        if let xPost = xPostContent(for: shown, base: base) {
            configuration.xPost = xPost.content
            configuration.onSelectXPostMedia = { [weak self] index, grid in
                self?.openMedia(xPost.media, at: index, of: shown, from: grid)
            }
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

    /// 注意書きの本文を開閉する。フィルターの警告で畳んでいれば、注意書きの代わりに警告を開く。同じ投稿をブーストした行と通知の行もまとめて描き直す。
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
        let shownID = status.displayed.id
        let ids = displayedItemIDs.filter { self.status(for: $0)?.displayed.id == shownID }
        reconfigure(Set(ids), keeping: anchorID)
    }

    func avatarContent(of account: Account) -> AvatarView.Content {
        postContentBuilder.avatarContent(of: account)
    }

    func body(of status: Status, base: UIListContentConfiguration, color: UIColor = .label) -> NSAttributedString {
        postContentBuilder.body(of: status, base: base, color: color)
    }

    /// 注意書き。開いているかは、この一覧で覚えている状態を当てる。ブーストなら元の投稿の注意書きにする。
    /// フィルターの警告で畳んでいれば、注意書きの代わりに警告を出す。警告を開くと、注意書きのある投稿は注意書きで畳んだ形に戻る。
    func spoiler(of status: Status, base: UIListContentConfiguration, color: UIColor = .label) -> PostBodyContent.Spoiler? {
        let warningTitles = filterWarnings.verdict(for: status).warningTitles
        guard warningTitles.isEmpty else { return postContentBuilder.filterWarning(titles: warningTitles, base: base) }
        var spoiler = postContentBuilder.spoiler(of: status.displayed, base: base, color: color)
        spoiler?.isCollapsed = spoilerExpansion.isCollapsed(status)
        return spoiler
    }
}

extension TimelineViewController: LinkMenuHost {
    func linkMenuWillShow() {
        UserAction.openMenu(screen: texts.dumpName).record()
        menuWillShow()
    }

    func linkMenuDidHide() {
        menuDidHide()
    }

    func showLinkCopiedNotice() {
        showNotice(.linkCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    func openURL(_ url: URL, in browser: LinkBrowser) {
        onOpenURL?(url, browser)
    }
}

extension TimelineViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isTracking {
            // 指が下へ動いていれば、内容は上の新しい投稿の方へ動く。
            let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView).y
            if velocity != 0 {
                lastScrollDirection = velocity > 0 ? .towardNewer : .towardOlder
            }
        }
        reportVisibleItems()
        reportApproachingGaps()
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
        stopScrollingToTop()
        // 慣性で動いている途中で触れると、前のスクロールは止まりの通知を受けずに終わるため、ここで記録する。
        recordScroll()
        scrollStart = (scrollView.contentOffset.y, CACurrentMediaTime())
        scrollHitches.start()
    }

    /// スクロールの途中で新着の挿入などにより位置を補正すると、補正の分も動いた量に入る。
    private func recordScroll() {
        guard let start = scrollStart else { return }
        scrollStart = nil
        let hitches = scrollHitches.stop()
        UserAction.scroll(ScrollRecord(
            screen: texts.dumpName,
            startOffset: start.offset,
            endOffset: collectionView.contentOffset.y,
            viewportHeight: collectionView.bounds.inset(by: collectionView.adjustedContentInset).height,
            duration: CACurrentMediaTime() - start.time,
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
    }

    /// メニューが閉じるアニメーションの間も行を動かさない。
    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        guard let animator else {
            menuDidHide()
            return
        }
        animator.addCompletion { [weak self] in self?.menuDidHide() }
    }

    /// 長押しで投稿への操作のメニューを出す。
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath), let entry = entry(for: id),
              let menu = contextMenu(for: entry, id: id)
        else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }

    /// 選べるのはギャップと、ブラウザで開ける読めなかった要素だけにする。投稿にはまだ開く画面がなく、タップすると選んだ状態の背景が残ったままになるため。
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        return switch (id, entries[id]) {
        case (.gap, _): true
        case (_, .unreadable(let item)): item.url != nil
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    /// ギャップは、画面の上半分にあれば下から遡ってきたとみなして古い側から、下半分にあれば新しい側から読む。
    /// どちらも、いま読んでいる側に続く投稿から埋まる。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
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
        gestureRecognizer === scrollToTopInterruption && otherGestureRecognizer === collectionView.panGestureRecognizer
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
    func currentAnchor() -> ScrollAnchor? {
        collectionView.layoutIfNeeded()
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let topmost = collectionView.indexPathsForVisibleItems
            .compactMap { indexPath -> (ItemID, CGRect)? in
                guard let id = dataSource.itemIdentifier(for: indexPath),
                      let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
                else { return nil }
                return (id, frame)
            }
            .filter { $0.1.maxY > visibleTop }
            .min { $0.1.minY < $1.1.minY }
        guard let (id, frame) = topmost else { return nil }
        return ScrollAnchor(id: id, distanceFromVisibleTop: frame.minY - visibleTop)
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
        let anchor = (headerFrame.map { $0.maxY <= visibleTop } ?? false) ? currentAnchor() : nil
        collectionView.collectionViewLayout.invalidateLayout()
        if let anchor {
            restore(anchor)
        } else {
            collectionView.layoutIfNeeded()
        }
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
        let anchor = anchorID.flatMap(anchor(of:)) ?? currentAnchor()
        dataSource.apply(snapshot, animatingDifferences: false)
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
    /// チップの列の上端。この画面の座標。ナビゲーションバーの下に置く。新着のボタンが出ていれば、その下。一番上から引っぱっても下げない。
    var noticeTop: CGFloat {
        var top = view.safeAreaInsets.top + 8
        if !newArrivalsButton.isHidden {
            top += newArrivalsButton.intrinsicContentSize.height + 8
        }
        return top
    }

    func noticePlacement(below: CGFloat) -> NoticePlacement {
        NoticePlacement(top: view.convert(CGPoint(x: 0, y: noticeTop), to: nil).y)
    }
}

/// タイムラインの一覧。本文のリンクを押して少し止めてから引いても、スクロールできるようにする。
final class TimelineCollectionView: UICollectionView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is LinkHitArea || super.touchesShouldCancel(in: view)
    }
}
