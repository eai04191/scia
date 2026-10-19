#if DEBUG
import SciaCore
import UIKit

/// 部品を状態ごとに切り離して並べ、見た目を確かめるカタログ（Storybookのようなもの）に載せる部品。
/// サーバーで失敗を起こしたり大きなファイルを上げたりせずに、失敗の表示などを直接出す。
/// 実物の部品をそのまま置くので、実機ではキーボード、文字の大きさ、ダークモードを変えて触れる。
///
/// デバッグメニューの「部品カタログ」か、`scia-debug://catalog/<rawValue>`で開く。
///
/// 次の部品は、AGENTS.mdの基準では載せるべきだが、外から状態を渡せないため載せていない。その部品に手を入れるときに、合わせて載せる。
/// - 接続の状態の画面（`ConnectionStatusView`）: `ConnectionDiagnostics.Status`にpublicなinitがなく、SciaCoreの外から作れない。`Status`を受け取る中身のビューを分けるか、publicなinitを足す
/// - 投稿欄（`InlineComposeController`）: 投稿中や添付の失敗は`ComposeModel`の`private(set)`で、`InlineComposeController`はタブバーとキーボードに頼る。残りの文字数のカプセルなどを切り出す
/// - ログイン画面のエラー（`LoginView`）: `isLoggingIn`が`private(set)`で、ログイン中を出すには実際の認可を待たせる必要がある
enum CatalogComponent: String, CaseIterable {
    case attachmentStrip = "attachment-strip"
    case completionList = "completion-list"
    case altTextEditor = "alt-text-editor"
    case caption
    case notices
    case operationStatus = "operation-status"
    case videoControls = "video-controls"
    case timelineEmpty = "timeline-empty"
    case timelineFooter = "timeline-footer"
    case timelineRows = "timeline-rows"
    case timelineOverlays = "timeline-overlays"
    case streamingStatus = "streaming-status"
    case mediaGrid = "media-grid"
    case profileHeader = "profile-header"
    case posts
    case linkCards = "link-cards"
    case notifications
    case editHistory = "edit-history"

    var title: String {
        switch self {
        case .attachmentStrip: "投稿欄の添付のサムネイル"
        case .completionList: "投稿欄の補完の候補"
        case .altTextEditor: "代替テキストの入力欄"
        case .caption: "ビューアの説明"
        case .notices: "アプリ内通知のチップの列"
        case .operationStatus: "操作の状況の一覧"
        case .videoControls: "動画の再生の操作"
        case .timelineEmpty: "タイムラインが空のときの表示"
        case .timelineFooter: "タイムラインの末尾"
        case .timelineRows: "読めない行とギャップの行"
        case .timelineOverlays: "一覧の上に重ねる表示"
        case .streamingStatus: "引っぱると見えるストリーミングの状態"
        case .mediaGrid: "一覧の添付ファイルのサムネイル"
        case .profileHeader: "プロフィールのヘッダー"
        case .posts: "一覧の投稿"
        case .linkCards: "リンクカード"
        case .notifications: "通知の種類"
        case .editHistory: "編集履歴の版"
        }
    }

    @MainActor
    func makeStates() -> [CatalogState] {
        switch self {
        case .attachmentStrip: AttachmentStripCatalog.states()
        case .completionList: CompletionListCatalog.states()
        case .altTextEditor: AltTextEditorCatalog.states()
        case .caption: CaptionCatalog.states()
        case .notices: NoticeCatalog.states()
        case .operationStatus: OperationStatusCatalog.states()
        case .videoControls: VideoControlsCatalog.states()
        case .timelineEmpty: TimelineCatalog.emptyStates()
        case .timelineFooter: TimelineCatalog.footerStates()
        case .timelineRows: TimelineCatalog.rowStates()
        case .timelineOverlays: TimelineOverlayCatalog.states()
        case .streamingStatus: StreamingStatusCatalog.states()
        case .mediaGrid: MediaGridCatalog.states()
        case .profileHeader: ProfileHeaderCatalog.states()
        case .posts: PostRowCatalog.postStates()
        case .linkCards: PostRowCatalog.linkCardStates()
        case .notifications: PostRowCatalog.notificationStates()
        case .editHistory: EditHistoryCatalog.states()
        }
    }
}

/// カタログで1つの見出しの下に並べる、ある状態の部品。
struct CatalogState {
    let title: String
    let makeView: @MainActor () -> UIView
}

/// ビューアのように画像の上に重ねる部品を置く下地。半透明の部品が画像に重なった見え方を確かめられるよう、格子の画像を敷く。
enum CatalogBackdrop {
    /// - Parameter constraints: 下地と部品を受け取り、部品の置き方を返す。下地の高さも、これで決まるようにする。
    @MainActor
    static func image(_ content: UIView, constraints: (_ backdrop: UIView, _ content: UIView) -> [NSLayoutConstraint]) -> UIView {
        let backdrop = UIView()
        backdrop.clipsToBounds = true
        let imageView = UIImageView(image: DummyMedia.image(size: CGSize(width: 800, height: 800), color: .systemOrange, label: ""))
        imageView.contentMode = .scaleAspectFill
        // 画像の大きさで下地が伸びないよう、高さは部品の置き方だけで決める。
        // 部品の中の文字と優先度が並ぶと高さが決まらないため、どちらも最も低くする。
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            imageView.setContentHuggingPriority(UILayoutPriority(1), for: axis)
            imageView.setContentCompressionResistancePriority(UILayoutPriority(1), for: axis)
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(imageView)
        backdrop.addSubview(content)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ] + constraints(backdrop, content))
        return backdrop
    }
}

/// ナビゲーションバーの小見出しのように、画面ごと置かないと実物どおりに見えない部品の入れ物。
/// 状態を並べる画面が`controller`を子の画面として抱え、決まった高さの枠に収める。
final class CatalogControllerHost: UIView {
    let controller: UIViewController

    init(_ controller: UIViewController, height: CGFloat) {
        self.controller = controller
        super.init(frame: .zero)
        clipsToBounds = true
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 1
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 画面の上に重ねるビューと、その置き方。ウインドウに重ねる部品（チップの列）を、画面が伝える位置に置いて見せる。
    private var overlay: (view: UIView, layout: (CatalogControllerHost, UIView) -> Void)?

    /// 画面の上に`view`を重ねる。並べ直すたびに`layout`で置く。
    func addOverlay(_ view: UIView, layout: @escaping (CatalogControllerHost, UIView) -> Void) {
        overlay = (view, layout)
        addSubview(view)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let overlay {
            // 重ねるビューは中の画面が伝える位置に置くため、中の画面を先に並べ終える。
            controller.view.layoutIfNeeded()
            bringSubviewToFront(overlay.view)
            overlay.layout(self, overlay.view)
        }
    }

    /// 子の画面として抱えた後に、画面のビューを枠いっぱいに置く。
    func installControllerView() {
        let view = controller.view ?? UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// 一覧の中に出す部品を置く枠。
enum CatalogFrame {
    /// 一覧の中の表示と同じく背景の上に置き、範囲が分かるよう枠を付ける。`height`を渡すと、その高さにする。
    @MainActor
    static func bordered(_ content: UIView, height: CGFloat? = nil) -> UIView {
        let frame = UIView()
        frame.backgroundColor = .systemBackground
        frame.layer.borderColor = UIColor.separator.cgColor
        frame.layer.borderWidth = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: frame.topAnchor),
            content.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
        ] + (height.map { [frame.heightAnchor.constraint(equalToConstant: $0)] } ?? []))
        return frame
    }
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
            let content = state.makeView()
            if let host = content as? CatalogControllerHost {
                addChild(host.controller)
                host.installControllerView()
                stack.addArrangedSubview(host)
                host.controller.didMove(toParent: self)
            } else {
                stack.addArrangedSubview(content)
            }
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
