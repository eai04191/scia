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

/// 投稿欄の添付のサムネイル（`ComposeAttachmentStrip`）の状態。
private enum AttachmentStripCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "種類と代替テキスト（画像、ALTあり、GIF、動画、ALTありの動画）") {
                strip([
                    item(.image, color: .systemBlue),
                    item(.image, color: .systemGreen, description: "代替テキスト"),
                    item(.gifv, color: .systemIndigo),
                    item(.video, color: .systemTeal),
                    item(.video, color: .systemOrange, description: "代替テキスト"),
                ])
            },
            CatalogState(title: "アップロード中（サムネイルあり、読み込み前）") {
                strip([
                    item(.image, color: .systemBlue, status: .uploading),
                    item(nil, color: .clear, status: .uploading),
                ])
            },
            CatalogState(title: "サーバーで処理中（画像、動画）") {
                strip([
                    item(.image, color: .systemBlue, status: .processing),
                    item(.video, color: .systemTeal, status: .processing),
                ])
            },
            CatalogState(title: "代替テキストを送信中（画像、GIF）") {
                strip([
                    item(.image, color: .systemGreen, description: "代替テキスト", status: .sendingDescription),
                    item(.gifv, color: .systemIndigo, description: "代替テキスト", status: .sendingDescription),
                ])
            },
            CatalogState(title: "アップロードできませんでした（画像、動画）") {
                strip([
                    item(.image, color: .systemBlue, status: .failed),
                    item(.video, color: .systemTeal, status: .failed),
                ])
            },
            CatalogState(title: "代替テキストを送信できませんでした（画像、GIF）") {
                strip([
                    item(.image, color: .systemGreen, description: "代替テキスト", status: .descriptionFailed),
                    item(.gifv, color: .systemIndigo, description: "代替テキスト", status: .descriptionFailed),
                ])
            },
            CatalogState(title: "幅に収まらず横にスクロールする（8枚）") {
                strip((1...8).map { index in
                    item(.image, color: index.isMultiple(of: 2) ? .systemPink : .systemPurple, label: "\(index)", description: index.isMultiple(of: 3) ? "代替テキスト" : "")
                })
            },
        ]
    }

    /// 並べ替えも試せるよう、移した結果をその列の中だけで描き直す。
    @MainActor
    private static func strip(_ items: [ComposeAttachmentStrip.Item]) -> UIView {
        let strip = ComposeAttachmentStrip()
        var items = items
        strip.update(items)
        strip.onMove = { [weak strip] id, index in
            guard let from = items.firstIndex(where: { $0.attachment.id == id }) else { return }
            let moved = items.remove(at: from)
            items.insert(moved, at: min(max(index, 0), items.count))
            strip?.update(items)
        }
        return strip
    }

    /// - Parameters:
    ///   - kind: nilなら、端末からまだ読み込んでいない添付にする。サムネイルもない。
    ///   - label: サムネイルの中央に描く文字。並べ替えを試す列で見分けるために付ける。ほかの列では、動画の再生の印と重ならないよう付けない。
    private static func item(
        _ kind: MediaAttachment.Kind?,
        color: UIColor,
        label: String = "",
        description: String = "",
        status: ComposeAttachmentStatus = .ready
    ) -> ComposeAttachmentStrip.Item {
        let id = UUID()
        let state: DraftAttachment.State = switch status {
        case .uploading: .uploading
        case .processing: .processing(serverID: id.uuidString)
        case .failed: .failed(serverID: nil)
        case .ready, .sendingDescription, .descriptionFailed:
            .uploaded(MediaAttachment(id: id.uuidString, type: kind ?? .image, url: nil, previewUrl: nil, description: description))
        }
        let local = LocalMedia(
            assetIdentifier: id.uuidString,
            load: { throw LocalMediaError.loadFailed },
            file: kind.map { LocalMediaFile(url: URL(filePath: "/dev/null"), mimeType: "", kind: $0) },
            thumbnail: kind.map { _ in DummyMedia.image(size: CGSize(width: 192, height: 192), color: color, label: label) }
        )
        return ComposeAttachmentStrip.Item(attachment: DraftAttachment(id: id, state: state, description: description), local: local, status: status)
    }
}
#endif
