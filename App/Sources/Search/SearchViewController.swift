import SciaCore
import UIKit

/// 検索の画面。上に検索欄を置き、打っている途中の候補と最近の検索の一覧と、確定した語の結果の一覧を中に入れる。決まりはdocs/search.mdにある。
/// 検索のタブの一番下の画面にするほか、検索を無効にしているときは、開いているタブに積んで開く。
///
/// 候補の一覧は、結果の一覧と同じ画面（`TimelineViewController`）で描き、ユーザーとハッシュタグの行を結果と同じ見た目にする。
/// `UISearchController`の結果の画面には載せない。結果の画面はナビゲーションの外に出るため、候補からプロフィールなどを積めないため。
/// 語を打っている間は候補の一覧を、語を確定したら結果の一覧を前に出す。
@MainActor
final class SearchViewController: UIViewController, UISearchBarDelegate, UISearchControllerDelegate, UISearchResultsUpdating {
    /// 確定した語の結果の一覧を作る。
    var makeResults: ((SearchInput) -> TimelineViewController)?
    /// 候補の一覧を作る。画面を読み込むときに1度だけ呼ぶ。
    var makeSuggestionsList: (() -> TimelineViewController)?
    /// 候補のハッシュタグと「#名前を開く」を押したときに呼ぶ。
    var onOpenHashtag: ((String, UIViewController) -> Void)?
    /// 打っている途中の候補と最近の検索。セッションが入れる。
    var suggestions: SearchSuggestions? {
        didSet {
            suggestions?.onChange = { [weak self] content in self?.show(content) }
            suggestions?.update(searchController.searchBar.text ?? "")
        }
    }
    private let searchController = UISearchController(searchResultsController: nil)
    /// 打っている途中の候補と最近の検索の一覧。
    private var suggestionsList: TimelineViewController?
    /// 確定した語の結果の一覧。まだ確定していなければnil。
    private(set) var results: TimelineViewController?
    /// 候補の一覧を前に出すか。語を打ち始めたら出し、確定したら引っ込める。
    private var showsSuggestions = true {
        didSet { updateFront() }
    }
    /// 開いたときに検索欄へフォーカスを入れるか。最初に見せるときだけにし、語を渡して開いたときは入れない。
    private var focusesOnAppear = true

    /// 見えている一覧。候補の一覧を出していれば候補の一覧、打っていなければ結果の一覧。
    var shownList: TimelineViewController? {
        isShowingSuggestions ? suggestionsList : showsSuggestions ? nil : results
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
        if let list = makeSuggestionsList?() {
            list.onSearchRowSelect = { [weak self] row in self?.select(row) }
            list.onRemoveRecentSearch = { [weak self] query in self?.suggestions?.removeRecent(query) }
            list.onRemoveAllRecentSearches = { [weak self] in self?.suggestions?.removeAllRecents() }
            embed(list)
            suggestionsList = list
            suggestions.map { show($0.content) }
        }
        updateFront()
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
        if results != nil {
            showsSuggestions = false
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        // 変換している途中の文字では探さない。確定する前の読みや打ちかけのローマ字で、サーバーに問い合わせないため。
        guard searchController.searchBar.searchTextField.markedTextRange == nil else { return }
        suggestions?.update(searchController.searchBar.text ?? "")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // 確定したあとに打ち直したら、また候補を出す。
        showsSuggestions = true
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        showsSuggestions = true
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submit(searchBar.text ?? "")
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
        case .heading, .recentsHeading, .showAll, .failed:
            break
        }
    }

    /// 語を確定し、その結果の一覧を出す。空の語では何もしない。
    func submit(_ text: String) {
        guard let input = SearchInput(text), let results = makeResults?(input) else { return }
        focusesOnAppear = false
        loadViewIfNeeded()
        searchController.searchBar.text = text
        // 欄の語を置き換えると候補を探し直すことがあるため、置き換えてから、探すのをやめて最近の検索に残す。
        suggestions?.submit(text)
        searchController.searchBar.resignFirstResponder()
        self.results.map(remove)
        embed(results)
        self.results = results
        showsSuggestions = false
    }

    private func show(_ content: SearchSuggestions.Content) {
        guard let list = suggestionsList else { return }
        // 打つたびに中身が入れ替わるので、行を基準にせず、スクロール位置をそのまま保つ。
        list.setEntries(content.entries, keeping: nil, placingAtTop: nil, keepsOffset: true, animatesRemoval: false, keepingRowContentsOf: nil)
        list.setContentState(.loaded)
        list.setFooterState(.idle)
        updateFront()
    }

    /// 候補の一覧を前に出しているか。候補が1つもなければ出さない。行のない一覧に、読み込み直すボタンが出るため。
    private var isShowingSuggestions: Bool {
        showsSuggestions && !(suggestions?.content.entries.isEmpty ?? true)
    }

    private func updateFront() {
        guard isViewLoaded else { return }
        suggestionsList?.view.isHidden = !isShowingSuggestions
        // 打っている間は、前に確定した語の結果を見せない。最近の検索がなく候補の一覧も出さないときに、欄の語と違う結果が見えるため。
        results?.view.isHidden = showsSuggestions
        if let front = shownList {
            view.bringSubviewToFront(front.view)
            // 見出しのバーと検索欄の下を流れる一覧として、端の効果と大きな題の縮みを前の一覧に合わせる。
            setContentScrollView(front.collectionView)
        }
    }

    /// 積んで開いた検索の画面を閉じたら、結果の一覧を外して読み込みをやめ、候補の問い合わせもやめる。
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent == nil else { return }
        results.map(remove)
        results = nil
        suggestions?.stop()
    }

    private func embed(_ list: TimelineViewController) {
        addChild(list)
        list.view.frame = view.bounds
        list.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(list.view)
        list.didMove(toParent: self)
    }

    private func remove(_ list: TimelineViewController) {
        list.willMove(toParent: nil)
        list.view.removeFromSuperview()
        list.removeFromParent()
    }
}

extension TimelineViewController {
    /// 画面に見えている一覧。検索の画面では、前に出している候補か結果の一覧。一覧のない画面ではnil。
    static func shown(in viewController: UIViewController?) -> TimelineViewController? {
        (viewController as? TimelineViewController) ?? (viewController as? SearchViewController)?.shownList
    }
}
