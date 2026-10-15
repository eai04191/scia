#if DEBUG
import SciaCore
import UIKit

/// 部品を状態ごとに切り離して並べ、見た目を確かめるカタログ（Storybookのようなもの）に載せる部品。
/// サーバーで失敗を起こしたり大きなファイルを上げたりせずに、失敗の表示などを直接出す。
/// 実物の部品をそのまま置くので、実機ではキーボード、文字の大きさ、ダークモードを変えて触れる。
///
/// デバッグメニューの「部品カタログ」か、`scia-debug://catalog/<rawValue>`で開く。
enum CatalogComponent: String, CaseIterable {
    case attachmentStrip = "attachment-strip"

    var title: String {
        switch self {
        case .attachmentStrip: "投稿欄の添付のサムネイル"
        }
    }

    @MainActor
    func makeStates() -> [CatalogState] {
        switch self {
        case .attachmentStrip: AttachmentStripCatalog.states()
        }
    }
}

/// カタログで1つの見出しの下に並べる、ある状態の部品。
struct CatalogState {
    let title: String
    let makeView: @MainActor () -> UIView
}

extension UIViewController {
    /// 部品のカタログを出す。`component`を渡すと、その部品の状態を並べた画面まで開く。
    /// カタログを出している上で呼ばれたら、重ねずに開いている画面を差し替える。URLで部品を次々に開くため。
    func presentComponentCatalog(opening component: CatalogComponent? = nil) {
        let list = ComponentCatalogViewController()
        let controllers: [UIViewController] = [list] + (component.map { [ComponentStatesViewController(component: $0)] } ?? [])
        if let navigation = self as? UINavigationController, navigation.viewControllers.first is ComponentCatalogViewController {
            navigation.setViewControllers(controllers, animated: false)
            return
        }
        let navigation = UINavigationController()
        navigation.setViewControllers(controllers, animated: false)
        present(navigation, animated: true)
    }
}

/// カタログに載せた部品の一覧。
final class ComponentCatalogViewController: UIViewController {
    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout.list(using: UICollectionLayoutListConfiguration(appearance: .insetGrouped))
    )
    private var dataSource: UICollectionViewDiffableDataSource<Int, CatalogComponent>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "部品カタログ"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, CatalogComponent> { cell, _, component in
            var content = cell.defaultContentConfiguration()
            content.text = component.title
            content.secondaryText = component.rawValue
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, CatalogComponent>(collectionView: collectionView) { collectionView, indexPath, component in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: component)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, CatalogComponent>()
        snapshot.appendSections([0])
        snapshot.appendItems(CatalogComponent.allCases)
        dataSource.apply(snapshot, animatingDifferences: false)
        self.dataSource = dataSource
    }
}

extension ComponentCatalogViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let component = dataSource?.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(ComponentStatesViewController(component: component), animated: true)
    }
}

/// 1つの部品の状態を、見出しを付けて縦に並べる。見比べられるよう、すべての状態を1画面に出す。
final class ComponentStatesViewController: UIViewController {
    private let component: CatalogComponent

    init(component: CatalogComponent) {
        self.component = component
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = component.title
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        for state in component.makeStates() {
            let label = UILabel()
            label.text = state.title
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(state.makeView())
            stack.setCustomSpacing(24, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        }
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        view.addSubview(scrollView)
        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scrollView.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.readableContentGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
        ])
    }
}
#endif
