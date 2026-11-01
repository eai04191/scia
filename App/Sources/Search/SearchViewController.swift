import SciaCore
import UIKit

/// 検索の画面。上に検索欄を置き、打っている途中の候補と最近の検索、確定した語の結果を、1つの一覧に入れ替えて並べる。決まりはdocs/search.mdにある。
/// 検索のタブの一番下の画面にするほか、検索を無効にしているときは、開いているタブに積んで開く。
///
/// 候補と結果は同じ一覧に並べる。両方にある行（同じ人、同じハッシュタグ、見出し）は、確定したときも打ち直したときも、その場に残す。
/// `UISearchController`の結果の画面には載せない。結果の画面はナビゲーションの外に出るため、候補からプロフィールなどを積めないため。
@MainActor
final class SearchViewController: UIViewController, UISearchBarDelegate, UISearchControllerDelegate, UISearchResultsUpdating {
    /// 確定した語の結果を読むモデルを作る。今の候補と、結果を並べる一覧を渡す。一覧に伝え始めるのと読み始めるのは、この画面が行う。
    var makeResults: ((SearchInput, SearchSuggestions.Content, TimelineViewController) -> SearchModel?)?
    /// 候補と結果を並べる一覧を作る。画面を読み込むときに1度だけ呼ぶ。
    var makeList: (() -> TimelineViewController)?
    /// 候補のハッシュタグと「#名前を開く」を押したときに呼ぶ。
    var onOpenHashtag: ((String, UIViewController) -> Void)?
    /// 結果の「すべて見る」を押したときに、確定した語とその種類を渡して呼ぶ。
    var onShowAll: ((SearchInput, SearchCategory, UIViewController) -> Void)?
    /// 打っている途中の候補と最近の検索。セッションが入れる。
    var suggestions: SearchSuggestions? {
        didSet {
            suggestions?.onChange = { [weak self] content in self?.show(content) }
            suggestions?.update(searchController.searchBar.text ?? "")
        }
    }
    private let searchController = UISearchController(searchResultsController: nil)
    /// 候補と結果を並べる一覧。
    private var list: TimelineViewController?
    /// 確定した語の結果。まだ確定していなければnil。
    private(set) var results: SearchModel?
    /// 候補を並べているか。語を打ち始めたら候補を、確定したら結果を並べる。
    private var showsSuggestions = true
    /// 打ち直す前に結果を見ていたスクロール位置。打ち直してから検索欄を閉じ、結果に戻すときに置き直す。
    private var resultsOffset: CGFloat?
    /// 開いたときに検索欄へフォーカスを入れるか。最初に見せるときだけにし、語を渡して開いたときは入れない。
    private var focusesOnAppear = true

    /// 見えている一覧。候補も結果もなく一覧を隠していればnil。
    var shownList: TimelineViewController? {
        list.flatMap { $0.view.isHidden ? nil : $0 }
    }

    /// 確定した語の結果を並べているか。打ち直している間はfalse。
    var isShowingResults: Bool {
        !showsSuggestions && results != nil
    }

    /// 並べている結果。候補を並べていればnil。
    private var shownResults: SearchModel? {
        showsSuggestions ? nil : results
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = TabItem.search.title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        searchController.delegate = self
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        // 一覧をスクロールしても、見出しを隠さず、検索欄を残す。
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = "ユーザー、ハッシュタグ、投稿、URL"
        searchController.searchBar.autocapitalizationType = .none
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        definesPresentationContext = true
        if let list = makeList?() {
            list.onSearchRowSelect = { [weak self] row in self?.select(row) }
            list.onRemoveRecentSearch = { [weak self] query in self?.suggestions?.removeRecent(query) }
            list.onRemoveAllRecentSearches = { [weak self] in self?.suggestions?.removeAllRecents() }
            list.onApproachingEnd = { [weak self] in self?.shownResults?.approachEnd() }
            list.onRetry = { [weak self] in self?.shownResults?.retry() }
            addChild(list)
            list.view.frame = view.bounds
            list.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(list.view)
            list.didMove(toParent: self)
            // 見出しのバーと検索欄の下を流れる一覧として、端の効果と大きな題の縮みを一覧に合わせる。
            setContentScrollView(list.collectionView)
            self.list = list
        }
        suggestions.map { show($0.content) }
        updateListVisibility()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 検索欄が空なら、開いてすぐ打てるようにする。
        guard focusesOnAppear, results == nil, searchController.searchBar.text?.isEmpty ?? true else { return }
        focusesOnAppear = false
        searchController.isActive = true
    }

    func didPresentSearchController(_ searchController: UISearchController) {
        searchController.searchBar.becomeFirstResponder()
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        // 検索欄を閉じたら、結果があれば結果に戻る。
        showResults()
    }

    func updateSearchResults(for searchController: UISearchController) {
        // 変換している途中の文字では探さない。確定する前の読みや打ちかけのローマ字で、サーバーに問い合わせないため。
        guard searchController.searchBar.searchTextField.markedTextRange == nil else { return }
        suggestions?.update(searchController.searchBar.text ?? "")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // 確定したあとに打ち直したら、また候補を出す。
        showSuggestions()
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        showSuggestions()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submit(searchBar.text ?? "")
    }

    /// 一覧を引っぱったときに、結果を並べていれば同じ語でもう一度探す。候補を並べている間は何もしない。
    func refreshResults() async {
        await shownResults?.refresh()
    }

    private func select(_ row: SearchRow) {
        switch row {
        case .action(.search(let text)):
            submit(text)
        case .action(.openURL(let url)):
            submit(url.absoluteString)
        case .action(.openHandle(let acct)):
            submit("@\(acct)")
        case .action(.openHashtag(let name)):
            suggestions?.submit("#\(name)")
            onOpenHashtag?(name, self)
        case .hashtag(let hashtag):
            onOpenHashtag?(hashtag.name, self)
        case .recent(let query):
            submit(query)
        case .showAll(let category):
            guard let results else { return }
            onShowAll?(results.input, category, self)
        case .failed(let category, _):
            results?.retry(category)
        case .heading, .recentsHeading:
            break
        }
    }

    /// 語を確定し、その結果を並べる。空の語では何もしない。
    func submit(_ text: String) {
        guard let input = SearchInput(text) else { return }
        focusesOnAppear = false
        loadViewIfNeeded()
        searchController.searchBar.text = text
        // 欄の語を置き換えると候補を探し直すことがあるため、置き換えてから、探すのをやめて最近の検索に残す。
        suggestions?.submit(text)
        // 候補のユーザーとハッシュタグは、結果が届くまで引き継ぐ。
        let carried = suggestions?.content ?? SearchSuggestions.Content()
        guard let list, let model = makeResults?(input, carried, list) else { return }
        searchController.searchBar.resignFirstResponder()
        results?.stop()
        results = model
        resultsOffset = nil
        showsSuggestions = false
        updateListVisibility()
        model.display = list
        model.start()
    }

    /// 候補を並べる。前に確定した語の結果は見せない。欄の語と違う結果が見えるため。
    private func showSuggestions() {
        guard !showsSuggestions else { return }
        showsSuggestions = true
        if let list {
            resultsOffset = list.collectionView.contentOffset.y
        }
        // 打っている間に届いた結果は、結果に戻したときに並べる。
        results?.display = nil
        suggestions.map { show($0.content) }
        if let collectionView = list?.collectionView {
            collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
        }
        updateListVisibility()
    }

    /// 確定した語の結果があれば、その結果に戻す。打ち直す前に見ていた位置に置き直す。
    private func showResults() {
        guard showsSuggestions, let results, let list else { return }
        showsSuggestions = false
        updateListVisibility()
        results.attach(list)
        if let resultsOffset {
            let collectionView = list.collectionView
            collectionView.layoutIfNeeded()
            let inset = collectionView.adjustedContentInset
            let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
            collectionView.contentOffset.y = min(resultsOffset, maxOffset)
        }
    }

    private func show(_ content: SearchSuggestions.Content) {
        guard showsSuggestions, let list else { return }
        // 打つたびに中身が入れ替わるので、行を基準にせず、スクロール位置をそのまま保つ。
        list.setEntries(content.entries, keeping: nil, placingAtTop: nil, keepsOffset: true, animatesRemoval: false, keepingRowContentsOf: nil)
        list.setContentState(.loaded)
        list.setFooterState(.idle)
        updateListVisibility()
    }

    /// 候補を並べていて、出す候補が1つもなければ一覧を隠す。行のない一覧に、見つからなかったことと読み込み直すボタンが出るため。
    private func updateListVisibility() {
        guard let list else { return }
        list.view.isHidden = showsSuggestions && (suggestions?.content.entries.isEmpty ?? true)
    }

    /// 積んで開いた検索の画面を閉じたら、結果の読み込みをやめ、候補の問い合わせもやめる。
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent == nil else { return }
        results?.stop()
        results = nil
        suggestions?.stop()
    }
}

extension TimelineViewController {
    /// 画面に見えている一覧。検索の画面では、候補か結果を並べている一覧。一覧のない画面ではnil。
    static func shown(in viewController: UIViewController?) -> TimelineViewController? {
        (viewController as? TimelineViewController) ?? (viewController as? SearchViewController)?.shownList
    }
}
