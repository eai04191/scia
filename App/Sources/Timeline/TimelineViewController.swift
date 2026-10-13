import os
import SciaCore
import UIKit

/// タイムライン表示。スクロール位置の制御を細かく行うため、UICollectionViewとdiffable data sourceで組む。
final class TimelineViewController: UIViewController {
    private enum Section { case main }

    private let logger = SciaLog.logger(category: "timeline")

    private(set) lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .plain))
    )
    private var dataSource: UICollectionViewDiffableDataSource<Section, Status.ID>!
    private var statuses: [Status.ID: Status] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        #if DEBUG
        navigationItem.rightBarButtonItem = makeDebugMenuButton()
        #endif
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        configureDataSource()
        AppDependencies.stateDumps.register("timeline", owner: self) { $0.stateDump() }
    }

    /// 表示中の投稿を、新しい順に並んだ`newStatuses`で置き換える。
    func setStatuses(_ newStatuses: [Status]) {
        statuses = Dictionary(newStatuses.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var snapshot = NSDiffableDataSourceSnapshot<Section, Status.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newStatuses.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
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

        let anchor = currentAnchor()
        dataSource.apply(snapshot, animatingDifferences: false)
        if let anchor {
            restore(anchor)
        }
        logger.info("prependStatuses count=\(newStatuses.count, privacy: .public) anchor=\(anchor?.id ?? "nil", privacy: .public)")
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
        """
    }

    func itemIdentifier(at indexPath: IndexPath) -> Status.ID? {
        dataSource.itemIdentifier(for: indexPath)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Status.ID> { [weak self] cell, _, id in
            guard let status = self?.statuses[id] else { return }
            var content = cell.defaultContentConfiguration()
            content.text = status.account.displayName
            content.secondaryText = status.content
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Status.ID>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
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
