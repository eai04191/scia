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

        static let home = Texts(dumpName: "timeline", title: "ホーム", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません")
        static let notifications = Texts(dumpName: "notifications", title: "通知", empty: "通知はありません", reachedEnd: "これより前の通知はありません")
    }

    /// 一覧全体の状態。投稿がないときの表示に使う。
    enum ContentState: Equatable {
        case loading
        case loaded
        /// サーバーがホームを再生成中で、まだ投稿が返ってこない。
        case regenerating
        case failed(String)
    }

    /// 末尾の読み込みの状態。フッターに出す。
    enum FooterState: Equatable {
        case idle
        case loading
        case failed(String)
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
    /// 投稿への操作が選ばれたときに呼ぶ。ブーストなら、ブーストした投稿を渡す。
    var onStatusAction: ((StatusAction, Status) -> Void)?
    /// 投稿ボタンが押されたときに呼ぶ。設定されていれば、ナビゲーションバーに投稿ボタンを出す。表示より前に設定する。
    var onCompose: (() -> Void)?
    /// ログイン中のアカウントのID。ブーストできる投稿かの判定に使う。
    var myAccountID: String?
    /// 指によるスクロールが止まったとき、または長押しのメニューが閉じたときに呼ぶ。
    var onInteractionSettle: (() -> Void)?
    /// ギャップがタップされたときに、どちらの端から読むかを添えて呼ぶ。
    var onGapSelect: ((String, TimelineStore.GapDirection) -> Void)?
    /// 読み込み中でないギャップが表示領域に近づいたときに、どちらの端から読むかを添えて呼ぶ。スクロールするたびに呼ぶことがある。
    var onGapApproach: ((String, TimelineStore.GapDirection) -> Void)?
    #if DEBUG
    /// デバッグメニューに出す、このタイムライン用の検証の操作。表示より前に設定する。
    var debugActions: [UIMenuElement] = []
    #endif

    /// 末尾から何件手前で古い投稿の読み込みを始めるか。
    private let prefetchThreshold = 10

    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    private var entries: [ItemID: TimelineEntry] = [:]
    private var loadingGapIDs: Set<String> = []
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
    /// 新着ボタンで最上部へ動かしている。
    private var isScrollingToTop = false
    private lazy var newArrivalsButton = makeNewArrivalsButton()
    private let texts: Texts
    let tuning: TuningStore
    let emojiImages: EmojiImageStore
    let mediaImages: MediaImageStore
    let network: NetworkConditionsMonitor
    /// 閲覧注意の覆いを外した投稿のID。ブーストなら元の投稿のID。
    var revealedMediaStatusIDs: Set<Status.ID> = []

    init(
        texts: Texts = .home,
        tuning: TuningStore = AppDependencies.tuning,
        emojiImages: EmojiImageStore = AppDependencies.emojiImages,
        mediaImages: MediaImageStore = AppDependencies.mediaImages,
        network: NetworkConditionsMonitor = AppDependencies.network
    ) {
        self.texts = texts
        self.tuning = tuning
        self.emojiImages = emojiImages
        self.mediaImages = mediaImages
        self.network = network
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = texts.title
        var barItems: [UIBarButtonItem] = []
        if onCompose != nil {
            let compose = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.onCompose?() })
            compose.accessibilityLabel = "投稿"
            barItems.append(compose)
        }
        #if DEBUG
        barItems.append(makeDebugMenuButton(screenActions: debugActions))
        #endif
        navigationItem.rightBarButtonItems = barItems
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        view.addSubview(newArrivalsButton)
        NSLayoutConstraint.activate([
            newArrivalsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            newArrivalsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        AppDependencies.stateDumps.register(texts.dumpName, owner: self) { $0.stateDump() }
        emojiImages.addListener(owner: self) { [weak self] urls in self?.emojiImagesDidLoad(urls) }
        observeTuning()
    }

    /// 他のタブにいる間に表示が変わっても既読にしないため、画面に出たときに改めて報告する。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reportVisibleItems()
    }

    /// チューニングの値や回線の状態が変わったら、表示中の投稿を描き直す。
    /// サムネイルは、低データモードを抜けたときなどに、表示中のものも読む画像を選び直す。
    private func observeTuning() {
        withObservationTracking {
            _ = tuning.value(of: TuningCatalog.paragraphSpacing)
            _ = tuning.value(of: TuningCatalog.mediaTallestAspectRatio)
            _ = tuning.value(of: TuningCatalog.mediaThumbnailUpscaleTolerance)
            _ = network.conditions
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
            case .status(let status): !Self.emojiURLs(of: status).isDisjoint(with: urls)
            case .notification(let notification): !Self.emojiURLs(of: notification).isDisjoint(with: urls)
            case .gap, nil: false
            }
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
    func reconfigure(_ ids: Set<ItemID>) {
        guard !ids.isEmpty else { return }
        guard !isShowingMenu else {
            heldReconfigureIDs.formUnion(ids)
            return
        }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(Array(ids))
        applyPreservingAnchor(snapshot)
    }

    /// 表示中の要素を、新しい順に並んだ`newEntries`で置き換える。
    ///
    /// 読んでいる位置の要素が画面上で動かないようにする。基準は表示領域の上端にかかっている要素で、`anchorID`を渡せばその要素にする。
    /// ただし最上部にいて追従が有効なら、最上部に留まって新着を見せる。
    /// `topID`を渡すと、その要素を表示領域の上端に置く。既読位置から読み始めるときに使う。
    func setEntries(_ newEntries: [TimelineEntry], keeping anchorID: ItemID? = nil, placingAtTop topID: ItemID? = nil) {
        guard !isShowingMenu else {
            // 後の呼び出しの並びが新しい。基準は、メニューが閉じたときに最後に指定されたものを使う。
            heldEntries = HeldEntries(entries: newEntries, anchorID: anchorID ?? heldEntries?.anchorID, topID: topID ?? heldEntries?.topID)
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
        } else if followsTop {
            // 最初に並べるときは、行が浮かび上がって見えないよう、アニメーションしない。
            let animates = !previous.isEmpty && tuning.value(of: TuningCatalog.animatesInsertionAtTop)
            isRestoringAnchor = true
            dataSource.apply(snapshot, animatingDifferences: animates) { [weak self] in
                // 動いている間に、見積もりから実寸へ変わったセルの分だけ位置が補正され、最上部から外れることがあるため、戻す。
                guard animates, let self, !self.isUserScrolling, !self.isAtTop else { return }
                self.collectionView.setContentOffset(CGPoint(x: 0, y: -self.collectionView.adjustedContentInset.top), animated: true)
            }
            collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
            isRestoringAnchor = false
            logger.info("setEntries count=\(newEntries.count, privacy: .public) followsTop=true animated=\(animates, privacy: .public)")
        } else {
            let anchor = applyPreservingAnchor(snapshot, keeping: anchorID)
            logger.info("setEntries count=\(newEntries.count, privacy: .public) anchor=\(anchor.map { Self.label($0.id) } ?? "nil", privacy: .public)")
        }
        setNeedsUpdateContentUnavailableConfiguration()
        reportVisibleItems()
        reportApproachingGaps()
    }

    /// 読み込み中のギャップを、読み込み中の表示にする。
    func setLoadingGaps(_ ids: Set<String>) {
        let changed = ids.symmetricDifference(loadingGapIDs).map(ItemID.gap)
        loadingGapIDs = ids
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
            setEntries(held.entries, keeping: held.anchorID, placingAtTop: held.topID)
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
        newArrivalsButton.isHidden = count == 0
        newArrivalsButton.configuration?.title = isLowerBound ? "\(count)件以上の新着" : "\(count)件の新着"
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
        guard dataSource.snapshot().numberOfItems == 0 else {
            contentUnavailableConfiguration = nil
            return
        }
        switch contentState {
        case .loading:
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .loaded:
            contentUnavailableConfiguration = emptyConfiguration(text: texts.empty, secondaryText: nil, buttonTitle: "再読み込み")
        case .regenerating:
            contentUnavailableConfiguration = emptyConfiguration(
                text: "ホームを準備しています",
                secondaryText: "しばらく使っていなかったため、サーバーがホームを作り直しています。少し待ってから読み込み直してください。",
                buttonTitle: "再読み込み"
            )
        case .failed(let message):
            contentUnavailableConfiguration = emptyConfiguration(text: "読み込めませんでした", secondaryText: message, buttonTitle: "再試行")
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
        """
    }

    /// ログと状態ダンプで要素を示す表記。投稿はID、ギャップは`gap-`で始まるID。
    private static func label(_ id: ItemID) -> String {
        switch id {
        case .status(let id): id
        case .gap(let id): id
        case .notification(let id): "notification-\(id)"
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

    private func makeNewArrivalsButton() -> UIButton {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "arrow.up")
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.scrollToNewest()
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }

    /// 最上部へ動かす。上のセルは表示されたときに見積もりから実寸へ変わり、そのぶん位置が補正されて最上部に届かないことがあるため、
    /// 届くまで動かし直す。
    func scrollToNewest() {
        isScrollingToTop = true
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
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
    /// 他のタブにいる間や、添付ファイルのビューアで覆っている間など、画面に出ていなければ報告しない。
    func reportVisibleItems() {
        guard !isRestoringAnchor, viewIfLoaded?.window != nil, !isCoveredByMediaViewer else { return }
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
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.footerMode = .supplementary
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
                let list = self.contentConfiguration(for: status, base: cell.defaultContentConfiguration())
                cell.contentConfiguration = self.statusContentConfiguration(list: list, status: status)
            case .gap(let gap):
                cell.contentConfiguration = self.gapContentConfiguration(isLoading: self.loadingGapIDs.contains(gap.id), base: cell.defaultContentConfiguration())
            case .notification(let notification):
                let list = self.contentConfiguration(for: notification, base: cell.defaultContentConfiguration())
                cell.contentConfiguration = self.statusContentConfiguration(list: list, notification: notification)
            }
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<TimelineFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] footer, _, _ in
            footer.onRetry = { self?.onRetry?() }
            self?.configure(footer)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, ItemID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
        return dataSource
    }

    private func configure(_ footer: TimelineFooterView) {
        footer.apply(footerState, reachedEndText: texts.reachedEnd)
    }

    func gapContentConfiguration(isLoading: Bool, base: UIListContentConfiguration) -> UIListContentConfiguration {
        var content = base
        content.text = isLoading ? "読み込み中…" : "読み込んでいない投稿を読み込む"
        content.textProperties.alignment = .center
        content.textProperties.color = isLoading ? .secondaryLabel : .tintColor
        return content
    }

    func contentConfiguration(for status: Status, base: UIListContentConfiguration) -> UIListContentConfiguration {
        var content = base
        let shown = status.displayed
        let nameRenderer = RichTextRenderer(font: base.textProperties.font, textColor: base.textProperties.color, emojiImages: emojiImages)
        let names = NSMutableAttributedString()
        if status.reblog != nil {
            var boosterRenderer = nameRenderer
            boosterRenderer.textColor = .secondaryLabel
            names.append(boosterRenderer.render(.plain(status.account.displayNameOrUsername, emojis: status.account.emojis)))
            names.append(NSAttributedString(
                string: "がブースト\n",
                attributes: [.font: base.textProperties.font, .foregroundColor: UIColor.secondaryLabel]
            ))
        }
        names.append(nameRenderer.render(.plain(shown.account.displayNameOrUsername, emojis: shown.account.emojis)))
        content.attributedText = names

        content.secondaryAttributedText = body(of: shown, base: base)
        return content
    }

    /// 投稿の本文。注意書きつきの投稿は、本文を開く操作がまだないため注意書きだけを出す。
    func body(of status: Status, base: UIListContentConfiguration) -> NSAttributedString {
        let bodyRenderer = RichTextRenderer(
            font: base.secondaryTextProperties.font,
            textColor: base.secondaryTextProperties.color,
            paragraphSpacing: tuning.value(of: TuningCatalog.paragraphSpacing),
            emojiImages: emojiImages
        )
        guard !status.spoilerText.isEmpty else {
            return bodyRenderer.render(.status(status))
        }
        let spoiler = NSMutableAttributedString(string: "注意書き: ", attributes: [
            .font: base.secondaryTextProperties.font,
            .foregroundColor: base.secondaryTextProperties.color,
        ])
        spoiler.append(bodyRenderer.render(.plain(status.spoilerText, emojis: status.emojis)))
        return spoiler
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
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            reportVisibleItemsAfterLayout()
            onInteractionSettle?()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportVisibleItemsAfterLayout()
        onInteractionSettle?()
    }

    /// 新着ボタンで最上部へ動かしたとき。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if isScrollingToTop, !isAtTop {
            scrollToNewest()
            return
        }
        isScrollingToTop = false
        reportVisibleItemsAfterLayout()
        onInteractionSettle?()
    }

    /// 最上部へ動かしている途中で指が触れたら、それ以上は動かし直さない。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isScrollingToTop = false
    }

    /// 指を離したときの勢いで向きを決め直す。慣性で動く間はこの向きのまま。
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if velocity.y != 0 {
            lastScrollDirection = velocity.y < 0 ? .towardNewer : .towardOlder
        }
    }

    /// ステータスバーのタップで最上部へ動かしたとき。
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        reportVisibleItemsAfterLayout()
        onInteractionSettle?()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
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
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath), let status = status(for: id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.statusMenu(for: status) })
    }

    /// 選べるのはギャップだけにする。投稿にはまだ開く画面がなく、タップすると選んだ状態の背景が残ったままになるため。
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .gap = dataSource.itemIdentifier(for: indexPath) { true } else { false }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    /// ギャップは、画面の上半分にあれば下から遡ってきたとみなして古い側から、下半分にあれば新しい側から読む。
    /// どちらも、いま読んでいる側に続く投稿から埋まる。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .gap(let gapID) = dataSource.itemIdentifier(for: indexPath) else { return }
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
