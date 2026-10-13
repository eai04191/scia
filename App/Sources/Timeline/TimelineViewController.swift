import SciaCore
import UIKit

/// タイムライン表示。スクロール位置の制御を細かく行うため、UICollectionViewとdiffable data sourceで組む。
final class TimelineViewController: UIViewController {
    private enum Section { case main }

    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .plain))
    )
    private var dataSource: UICollectionViewDiffableDataSource<Section, Status.ID>!
    private var statuses: [Status.ID: Status] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        configureDataSource()
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
