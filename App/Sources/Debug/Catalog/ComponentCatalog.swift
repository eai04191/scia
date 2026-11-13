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
    case composeCapsule = "compose-capsule"
    case completionList = "completion-list"
    case emojiPalette = "emoji-palette"
    case composePoll = "compose-poll"
    case postingLanguage = "posting-language"
    case extendedURL = "extended-url"
    case altTextEditor = "alt-text-editor"

    case timelineEmpty = "timeline-empty"
    case timelineFooter = "timeline-footer"
    case timelineUnreadable = "timeline-unreadable"
    case timelineGap = "timeline-gap"
    case timelineOverlays = "timeline-overlays"
    case streamingStatus = "streaming-status"

    case postBody = "post-body"
    case postLabels = "post-labels"
    case postInteracted = "post-interacted"
    case postWarnings = "post-warnings"
    case postsMediaBeside = "posts-media-beside"
    case mediaGrid = "media-grid"
    case linkCards = "link-cards"
    case quotes
    case polls
    case emojiReactions = "emoji-reactions"
    case postActionBar = "post-action-bar"
    case translationTransition = "translation-transition"
    case hdrEmoji = "hdr-emoji"
    case editHistory = "edit-history"

    case notifications
    case accounts
    case notificationRequests = "notification-requests"

    case caption
    case videoControls = "video-controls"
    case mediaStatus = "media-status"

    case profileHeader = "profile-header"
    case profileAccent = "profile-accent"
    case profileEdit = "profile-edit"

    case notices
    case noticeLayout = "notice-layout"
    case statusBarTicker = "status-bar-ticker"
    case operationStatus = "operation-status"

    case announcements
    case reportSheet = "report-sheet"
    case login
    case crashReport = "crash-report"
    case listMembership = "list-membership"
    case filters

    case storage
    case mediaCache = "media-cache"

    /// 検索の語が、名前かURLの名前（`rawValue`）に含まれるか。
    func matches(_ query: String) -> Bool {
        title.localizedStandardContains(query) || rawValue.localizedStandardContains(query)
    }

    var title: String {
        switch self {
        case .attachmentStrip: "投稿欄の添付のサムネイル"
        case .composeCapsule: "書いていないときの投稿欄"
        case .completionList: "投稿欄の補完の候補"
        case .emojiPalette: "投稿欄のカスタム絵文字のパレット"
        case .composePoll: "投稿欄の投票の欄"
        case .postingLanguage: "投稿の言語を選ぶシート"
        case .extendedURL: "URLの後ろに続いた文字のシート"
        case .altTextEditor: "代替テキストの入力欄"
        case .caption: "ビューアの説明"
        case .translationTransition: "自動翻訳の置き換え（繰り返す）"
        case .notices: "アプリ内通知のチップの種類"
        case .noticeLayout: "アプリ内通知のチップの並べ方"
        case .statusBarTicker: "ステータスバーの通知"
        case .operationStatus: "操作の状況のリスト"
        case .videoControls: "動画の再生の操作"
        case .mediaStatus: "ビューアの読み込み中と見せられないとき"
        case .timelineEmpty: "タイムラインが空のときの表示"
        case .timelineFooter: "タイムラインの末尾"
        case .timelineUnreadable: "読めない投稿と通知の行"
        case .timelineGap: "ギャップの行"
        case .timelineOverlays: "タイムラインの上に重ねる表示"
        case .streamingStatus: "引っぱると見える新着の経路"
        case .mediaGrid: "タイムラインの添付ファイルのサムネイル"
        case .profileHeader: "プロフィールのヘッダー"
        case .profileAccent: "プロフィールのカードの色"
        case .postBody: "投稿の本文"
        case .postLabels: "投稿のラベルと名前"
        case .postInteracted: "お気に入りとブースト済みの投稿"
        case .postWarnings: "投稿の注意書きとフィルター"
        case .postsMediaBeside: "投稿（添付ファイルを本文の右に小さく）"
        case .linkCards: "リンクカード"
        case .quotes: "投稿の中の引用"
        case .polls: "投稿の投票"
        case .emojiReactions: "投稿の絵文字のリアクション"
        case .postActionBar: "投稿のアクションバー"
        case .notifications: "通知の種類"
        case .accounts: "人のリストの行"
        case .notificationRequests: "保留中の通知の行"
        case .editHistory: "編集履歴の版"
        case .announcements: "サーバーのお知らせ"
        case .hdrEmoji: "HDRのカスタム絵文字"
        case .reportSheet: "通報のシート"
        case .login: "最初の起動のログイン画面"
        case .crashReport: "クラッシュした投稿の報告"
        case .listMembership: "リストに追加のシート"
        case .filters: "フィルター"
        case .profileEdit: "プロフィールの編集"
        case .storage: "設定のストレージ"
        case .mediaCache: "ストレージのメディアのキャッシュ"
        }
    }

    @MainActor
    func makeStates() -> [CatalogState] {
        switch self {
        case .attachmentStrip: AttachmentStripCatalog.states()
        case .composeCapsule: ComposeCapsuleCatalog.states()
        case .completionList: CompletionListCatalog.states()
        case .emojiPalette: EmojiPaletteCatalog.states()
        case .composePoll: ComposePollEditorCatalog.states()
        case .postingLanguage: PostingLanguageCatalog.states()
        case .extendedURL: ExtendedURLCatalog.states()
        case .altTextEditor: AltTextEditorCatalog.states()
        case .caption: CaptionCatalog.states()
        case .translationTransition: [CatalogState(title: "投稿") { CatalogFrame.bordered(TranslationTransitionLoopView(), height: 240) }]
        case .notices: NoticeCatalog.kindStates()
        case .noticeLayout: NoticeCatalog.layoutStates()
        case .statusBarTicker: StatusBarTickerCatalog.states()
        case .operationStatus: OperationStatusCatalog.states()
        case .videoControls: VideoControlsCatalog.states()
        case .mediaStatus: MediaStatusCatalog.states()
        case .timelineEmpty: TimelineCatalog.emptyStates()
        case .timelineFooter: TimelineCatalog.footerStates()
        case .timelineUnreadable: TimelineCatalog.unreadableStates()
        case .timelineGap: TimelineCatalog.gapStates()
        case .timelineOverlays: TimelineOverlayCatalog.states()
        case .streamingStatus: StreamingStatusCatalog.states()
        case .mediaGrid: MediaGridCatalog.states()
        case .profileHeader: ProfileHeaderCatalog.states()
        case .profileAccent: ProfileHeaderCatalog.accentStates()
        case .postBody: PostRowCatalog.postBodyStates()
        case .postLabels: PostRowCatalog.postLabelStates()
        case .postInteracted: PostRowCatalog.postInteractedStates()
        case .postWarnings: PostRowCatalog.postWarningStates()
        case .postsMediaBeside: PostRowCatalog.mediaBesideStates()
        case .linkCards: PostRowCatalog.linkCardStates()
        case .quotes: PostRowCatalog.quoteStates()
        case .polls: PollCatalog.states()
        case .emojiReactions: EmojiReactionCatalog.states()
        case .postActionBar: PostActionBarCatalog.states()
        case .notifications: PostRowCatalog.notificationStates()
        case .accounts: PostRowCatalog.accountStates()
        case .notificationRequests: PostRowCatalog.notificationRequestStates()
        case .editHistory: EditHistoryCatalog.states()
        case .announcements: AnnouncementsCatalog.states()
        case .hdrEmoji: HDREmojiCatalog.states()
        case .reportSheet: ReportSheetCatalog.states()
        case .login: LoginCatalog.states()
        case .crashReport: CrashReportCatalog.states()
        case .listMembership: ListMembershipCatalog.states()
        case .filters: FiltersCatalog.states()
        case .profileEdit: ProfileEditCatalog.states()
        case .storage: StorageCatalog.states()
        case .mediaCache: StorageCatalog.mediaCacheStates()
        }
    }
}

/// カタログのリストで、部品をまとめるセクション。部品が出る画面ごとに分ける。
enum CatalogSection: CaseIterable {
    case compose
    case timeline
    case post
    case notificationsAndAccounts
    case viewer
    case profile
    case appWide
    case sheets
    case settings

    var title: String {
        switch self {
        case .compose: "投稿欄"
        case .timeline: "タイムライン"
        case .post: "投稿"
        case .notificationsAndAccounts: "通知と人"
        case .viewer: "ビューア"
        case .profile: "プロフィール"
        case .appWide: "アプリ全体"
        case .sheets: "シート"
        case .settings: "設定"
        }
    }

    /// セクションに入れる部品。リストには、この順に並べる。
    var components: [CatalogComponent] {
        switch self {
        case .compose: [.attachmentStrip, .composeCapsule, .completionList, .emojiPalette, .composePoll, .postingLanguage, .extendedURL, .altTextEditor]
        case .timeline: [.timelineEmpty, .timelineFooter, .timelineUnreadable, .timelineGap, .timelineOverlays, .streamingStatus]
        case .post: [.postBody, .postLabels, .postInteracted, .postWarnings, .postsMediaBeside, .mediaGrid, .linkCards, .quotes, .polls, .emojiReactions, .postActionBar, .translationTransition, .hdrEmoji, .editHistory]
        case .notificationsAndAccounts: [.notifications, .accounts, .notificationRequests]
        case .viewer: [.caption, .videoControls, .mediaStatus]
        case .profile: [.profileHeader, .profileAccent, .profileEdit]
        case .appWide: [.notices, .noticeLayout, .statusBarTicker, .operationStatus, .login]
        case .sheets: [.announcements, .reportSheet, .crashReport, .listMembership, .filters]
        case .settings: [.storage, .mediaCache]
        }
    }

    /// 検索の語に一致する部品を、セクションごとに返す。語が空ならすべて返し、部品が残らないセクションは省く。
    static func contents(matching query: String) -> [(section: CatalogSection, components: [CatalogComponent])] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.compactMap { section in
            let components = section.components.filter { query.isEmpty || $0.matches(query) }
            return components.isEmpty ? nil : (section, components)
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

/// タイムラインの中に出す部品を置く枠。
enum CatalogFrame {
    /// タイムラインの中の表示と同じく背景の上に置き、範囲が分かるよう枠を付ける。`height`を渡すと、その高さにする。
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

    /// タイムラインの投稿の行の中身を枠に置く。カスタム絵文字の画像は後から届くので、タイムラインと同じく、届いたら組み立て直す。
    /// 組み立てを1回で済ませると、名前や本文、リアクションのカスタム絵文字が空いたままになるため。
    @MainActor
    static func post(_ configuration: @escaping @MainActor () -> PostContentConfiguration) -> UIView {
        let view = PostContentView(configuration: configuration())
        AppDependencies.emojiImages.addListener(owner: view) { [weak view] _ in
            view?.configuration = configuration()
        }
        return bordered(view)
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

/// カタログに載せた部品のリスト。セクションに分けて並べ、検索欄で名前とURLの名前から絞り込む。
final class ComponentCatalogViewController: UIViewController, UISearchResultsUpdating {
    private lazy var collectionView: UICollectionView = {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        return UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }()

    private var dataSource: UICollectionViewDiffableDataSource<CatalogSection, CatalogComponent>?
    private let searchController = UISearchController(searchResultsController: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "部品カタログ"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.autocapitalizationType = .none
        // ペーストした文字を、コピーしたとおりに入れる。理由は`GlyphLanguageTextView`の`smartInsertDeleteType`と同じ。
        searchController.searchBar.searchTextField.smartInsertDeleteType = .no
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        view.addSubview(collectionView)
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, CatalogComponent> { cell, _, component in
            var content = cell.defaultContentConfiguration()
            content.text = component.title
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let dataSource = UICollectionViewDiffableDataSource<CatalogSection, CatalogComponent>(collectionView: collectionView) { collectionView, indexPath, component in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: component)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak dataSource] cell, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = dataSource?.sectionIdentifier(for: indexPath.section)?.title
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        self.dataSource = dataSource
        apply(query: "")
    }

    func updateSearchResults(for searchController: UISearchController) {
        apply(query: searchController.searchBar.text ?? "")
    }

    private func apply(query: String) {
        var snapshot = NSDiffableDataSourceSnapshot<CatalogSection, CatalogComponent>()
        for (section, components) in CatalogSection.contents(matching: query) {
            snapshot.appendSections([section])
            snapshot.appendItems(components, toSection: section)
        }
        dataSource?.apply(snapshot, animatingDifferences: false)
        contentUnavailableConfiguration = snapshot.numberOfItems == 0 ? UIContentUnavailableConfiguration.search() : nil
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
