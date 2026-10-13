import os
import SciaCore
import UIKit

/// タイムライン表示。スクロール位置の制御を細かく行うため、UICollectionViewとdiffable data sourceで組む。
final class TimelineViewController: UIViewController {
    private enum Section { case main }

    private let logger = SciaLog.logger(category: "timeline")

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

    /// 末尾から何件手前で古い投稿の読み込みを始めるか。
    private let prefetchThreshold = 10

    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    private var statuses: [Status.ID: Status] = [:]
    private(set) var contentState = ContentState.loaded
    private(set) var footerState = FooterState.idle
    private let emojiImages: EmojiImageStore
    /// 本文の段落と段落のあいだの余白。
    private let paragraphSpacing: CGFloat = 6

    init(emojiImages: EmojiImageStore = AppDependencies.emojiImages) {
        self.emojiImages = emojiImages
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        #if DEBUG
        navigationItem.rightBarButtonItem = makeDebugMenuButton()
        #endif
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        AppDependencies.stateDumps.register("timeline", owner: self) { $0.stateDump() }
        emojiImages.addListener(owner: self) { [weak self] urls in self?.emojiImagesDidLoad(urls) }
    }

    /// 絵文字の画像が届いたら、その絵文字を使う投稿だけを描き直す。
    private func emojiImagesDidLoad(_ urls: Set<URL>) {
        let ids = dataSource.snapshot().itemIdentifiers.filter { id in
            guard let status = statuses[id] else { return false }
            return !Self.emojiURLs(of: status).isDisjoint(with: urls)
        }
        reconfigure(Set(ids))
    }

    private static func emojiURLs(of status: Status) -> Set<URL> {
        let shown = status.displayed
        return Set((shown.emojis + shown.account.emojis + status.account.emojis).map(\.staticUrl))
    }

    /// 内容が変わってセルの高さが変わっても、読んでいる位置が動かないように描き直す。
    func reconfigure(_ ids: Set<Status.ID>) {
        guard !ids.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(Array(ids))
        applyPreservingAnchor(snapshot)
    }

    /// 表示中の投稿を、新しい順に並んだ`newStatuses`で置き換える。
    func setStatuses(_ newStatuses: [Status]) {
        let previous = statuses
        statuses = Dictionary(newStatuses.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var snapshot = NSDiffableDataSourceSnapshot<Section, Status.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newStatuses.map(\.id))
        // 差分はIDで取られるため、同じIDのまま内容が変わった投稿は明示的にセルを再構成する。
        let changedIDs = newStatuses.filter { status in previous[status.id].map { $0 != status } ?? false }.map(\.id)
        snapshot.reconfigureItems(Array(Set(changedIDs)))
        dataSource.apply(snapshot, animatingDifferences: false)
        setNeedsUpdateContentUnavailableConfiguration()
        logger.info("setStatuses count=\(newStatuses.count, privacy: .public)")
    }

    /// 新しい順に並んだ`newStatuses`を先頭に挿入する。読んでいる位置の投稿が画面上で動かないように、挿入後にcontentOffsetを補正する。
    func prependStatuses(_ newStatuses: [Status]) {
        for status in newStatuses {
            statuses[status.id] = status
        }
        var snapshot = dataSource.snapshot()
        let ids = newStatuses.map(\.id)
        if let first = snapshot.itemIdentifiers.first {
            snapshot.insertItems(ids, beforeItem: first)
        } else {
            snapshot.appendItems(ids)
        }

        let anchor = applyPreservingAnchor(snapshot)
        logger.info("prependStatuses count=\(newStatuses.count, privacy: .public) anchor=\(anchor?.id ?? "nil", privacy: .public)")
    }

    /// 古い順の末尾に`olderStatuses`（新しい順）を足す。表示中の位置は変わらない。
    func appendStatuses(_ olderStatuses: [Status]) {
        for status in olderStatuses {
            statuses[status.id] = status
        }
        var snapshot = dataSource.snapshot()
        snapshot.appendItems(olderStatuses.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        logger.info("appendStatuses count=\(olderStatuses.count, privacy: .public)")
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
            contentUnavailableConfiguration = emptyConfiguration(text: "投稿がありません", secondaryText: nil, buttonTitle: "再読み込み")
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
        let visibleIDs = collectionView.indexPathsForVisibleItems.sorted().compactMap { dataSource.itemIdentifier(for: $0) }
        let anchor = currentAnchor()
        return """
        items: \(dataSource.snapshot().numberOfItems)
        contentOffset.y: \(collectionView.contentOffset.y)
        contentSize.height: \(collectionView.contentSize.height)
        adjustedContentInset.top: \(collectionView.adjustedContentInset.top)
        visibleItems: \(visibleIDs.joined(separator: ", "))
        anchor: \(anchor.map { "\($0.id) distanceFromVisibleTop=\($0.distanceFromVisibleTop)" } ?? "nil")
        contentState: \(contentState)
        footerState: \(footerState)
        """
    }

    func itemIdentifier(at indexPath: IndexPath) -> Status.ID? {
        dataSource.itemIdentifier(for: indexPath)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.footerMode = .supplementary
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, Status.ID> {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Status.ID> { [weak self] cell, _, id in
            guard let self, let status = self.statuses[id] else { return }
            cell.contentConfiguration = self.contentConfiguration(for: status, base: cell.defaultContentConfiguration())
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<TimelineFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] footer, _, _ in
            footer.onRetry = { self?.onRetry?() }
            self?.configure(footer)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Status.ID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Status.ID>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
        return dataSource
    }

    private func configure(_ footer: TimelineFooterView) {
        footer.apply(footerState)
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

        let bodyRenderer = RichTextRenderer(
            font: base.secondaryTextProperties.font,
            textColor: base.secondaryTextProperties.color,
            paragraphSpacing: paragraphSpacing,
            emojiImages: emojiImages
        )
        // 注意書きつきの投稿は、本文を開く操作がまだないため注意書きだけを出す。
        if shown.spoilerText.isEmpty {
            content.secondaryAttributedText = bodyRenderer.render(.status(shown))
        } else {
            let spoiler = NSMutableAttributedString(string: "注意書き: ", attributes: [
                .font: base.secondaryTextProperties.font,
                .foregroundColor: base.secondaryTextProperties.color,
            ])
            spoiler.append(bodyRenderer.render(.plain(shown.spoilerText, emojis: shown.emojis)))
            content.secondaryAttributedText = spoiler
        }
        return content
    }
}

extension TimelineViewController: UICollectionViewDelegate {
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
        let id: Status.ID
        let distanceFromVisibleTop: CGFloat
    }

    /// 表示領域の上端にかかっている、最も上の投稿を基準にする。
    func currentAnchor() -> ScrollAnchor? {
        collectionView.layoutIfNeeded()
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let topmost = collectionView.indexPathsForVisibleItems
            .compactMap { indexPath -> (Status.ID, CGRect)? in
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

    /// スナップショットを当て、更新前に表示領域の上端にあった投稿を同じ位置に戻す。戻した基準を返す。
    @discardableResult
    private func applyPreservingAnchor(_ snapshot: NSDiffableDataSourceSnapshot<Section, Status.ID>) -> ScrollAnchor? {
        let anchor = currentAnchor()
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
