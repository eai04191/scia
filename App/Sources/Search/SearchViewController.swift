import SciaCore
import UIKit

/// 検索の画面。上に検索欄を置き、確定した語の結果の一覧を中に入れる。決まりはdocs/search.mdにある。
/// 検索のタブの一番下の画面にするほか、検索を無効にしているときは、開いているタブに積んで開く。
@MainActor
final class SearchViewController: UIViewController, UISearchBarDelegate, UISearchControllerDelegate {
    /// 確定した語の結果の一覧を作る。
    var makeResults: ((SearchInput) -> TimelineViewController)?
    private let searchController = UISearchController(searchResultsController: nil)
    /// 確定した語の結果の一覧。まだ確定していなければnil。
    private(set) var results: TimelineViewController?
    /// 開いたときに検索欄へフォーカスを入れるのを、次に見せるときだけにするか。語を渡して開いたときは入れない。
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
        searchController.obscuresBackgroundDuringPresentation = false
        // 結果の一覧をスクロールしても、見出しを隠さず、検索欄を残す。
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = "ユーザー、ハッシュタグ、投稿、URL"
        searchController.searchBar.autocapitalizationType = .none
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        definesPresentationContext = true
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

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submit(searchBar.text ?? "")
    }

    /// 語を確定し、その結果の一覧を出す。空の語では何もしない。
    func submit(_ text: String) {
        guard let input = SearchInput(text), let results = makeResults?(input) else { return }
        focusesOnAppear = false
        loadViewIfNeeded()
        searchController.searchBar.text = text
        searchController.searchBar.resignFirstResponder()
        show(results)
    }

    /// 積んで開いた検索の画面を閉じたら、結果の一覧を外して読み込みをやめる。
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent == nil else { return }
        results.map(remove)
        results = nil
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
