import SciaCore
import SwiftUI
import UIKit

/// 検索の画面。上に検索欄を置き、確定した語の結果の一覧を中に入れる。決まりはdocs/search.mdにある。
/// 検索のタブの一番下の画面にするほか、検索を無効にしているときは、開いているタブに積んで開く。
///
/// 打っている途中の候補と最近の検索は、`UISearchController`の結果の画面に出す。語を確定したら結果の画面を隠し、結果の一覧を見せる。
@MainActor
final class SearchViewController: UIViewController, UISearchBarDelegate, UISearchControllerDelegate, UISearchResultsUpdating {
    /// 確定した語の結果の一覧を作る。
    var makeResults: ((SearchInput) -> TimelineViewController)?
    /// 候補のユーザーを押したときに呼ぶ。
    var onOpenProfile: ((Account, UIViewController) -> Void)?
    /// 候補のハッシュタグと「#名前を開く」を押したときに呼ぶ。
    var onOpenHashtag: ((String, UIViewController) -> Void)?
    /// 打っている途中の候補と最近の検索。セッションが入れる。
    var suggestions: SearchSuggestions? {
        didSet {
            suggestions?.onChange = { [weak self] content in self?.suggestionsModel.content = content }
            suggestions?.update(searchController.searchBar.text ?? "")
        }
    }
    private let suggestionsModel = SearchSuggestionsModel()
    private lazy var searchController = UISearchController(searchResultsController: UIHostingController(rootView: SearchSuggestionsView(model: suggestionsModel)))
    /// 確定した語の結果の一覧。まだ確定していなければnil。
    private(set) var results: TimelineViewController?
    /// 開いたときに検索欄へフォーカスを入れるか。最初に見せるときだけにし、語を渡して開いたときは入れない。
    private var focusesOnAppear = true

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
        // 検索欄が空でも、最近の検索を出す。
        searchController.showsSearchResultsController = true
        // 結果の一覧をスクロールしても、見出しを隠さず、検索欄を残す。
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = "ユーザー、ハッシュタグ、投稿、URL"
        searchController.searchBar.autocapitalizationType = .none
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        definesPresentationContext = true
        suggestionsModel.onAction = { [weak self] action in self?.perform(action) }
        suggestionsModel.onSelectAccount = { [weak self] account in
            guard let self else { return }
            onOpenProfile?(account, self)
        }
        suggestionsModel.onSelectHashtag = { [weak self] hashtag in
            guard let self else { return }
            onOpenHashtag?(hashtag.name, self)
        }
        suggestionsModel.onSelectRecent = { [weak self] query in self?.submit(query) }
        suggestionsModel.onRemoveRecent = { [weak self] query in self?.suggestions?.removeRecent(query) }
        suggestionsModel.onRemoveAllRecents = { [weak self] in self?.suggestions?.removeAllRecents() }
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

    func updateSearchResults(for searchController: UISearchController) {
        // 変換している途中の文字では探さない。確定する前の読みや打ちかけのローマ字で、サーバーに問い合わせないため。
        guard searchController.searchBar.searchTextField.markedTextRange == nil else { return }
        suggestions?.update(searchController.searchBar.text ?? "")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // 確定したあとに打ち直したら、また候補を出す。
        searchController.showsSearchResultsController = true
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchController.showsSearchResultsController = true
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submit(searchBar.text ?? "")
    }

    private func perform(_ action: SearchSuggestions.Action) {
        switch action {
        case .search(let text):
            submit(text)
        case .openURL(let url):
            submit(url.absoluteString)
        case .openHandle(let acct):
            submit("@\(acct)")
        case .openHashtag(let name):
            suggestions?.submit("#\(name)")
            onOpenHashtag?(name, self)
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
        searchController.showsSearchResultsController = false
        show(results)
    }

    /// 積んで開いた検索の画面を閉じたら、結果の一覧を外して読み込みをやめ、候補の問い合わせもやめる。
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent == nil else { return }
        results.map(remove)
        results = nil
        suggestions?.stop()
    }

    private func remove(_ results: TimelineViewController) {
        results.willMove(toParent: nil)
        results.view.removeFromSuperview()
        results.removeFromParent()
    }

    private func show(_ results: TimelineViewController) {
        self.results.map(remove)
        addChild(results)
        results.view.frame = view.bounds
        results.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(results.view)
        results.didMove(toParent: self)
        // 見出しのバーと検索欄の下を流れる一覧として、端の効果と大きな題の縮みをこの一覧に合わせる。
        setContentScrollView(results.collectionView)
        self.results = results
    }
}

extension TimelineViewController {
    /// 画面に見えている一覧。検索の画面では、中に入れた結果の一覧。一覧のない画面ではnil。
    static func shown(in viewController: UIViewController?) -> TimelineViewController? {
        (viewController as? TimelineViewController) ?? (viewController as? SearchViewController)?.results
    }
}
