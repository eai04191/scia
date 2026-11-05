@testable import Scia
import SciaTesting
import Testing
import UIKit

/// 検索欄のフォーカス。検索のタブを開くとフォーカスを入れ、タブをもう一度押すと、検索欄を閉じていても入れ直す。空いたところを押すとキーボードを閉じる。
@MainActor
@Suite(.serialized) struct SearchFieldFocusTests {
    /// 開いたときに、検索欄にフォーカスを入れる。
    @Test func openingFocusesSearchField() async throws {
        let search = SearchViewController()
        let window = try Self.window(showing: search)
        defer { window.isHidden = true }
        let field = try #require(search.navigationItem.searchController).searchBar.searchTextField

        try await waitUntil { field.isFirstResponder }
    }

    /// フォーカスのない検索欄で、検索のタブをもう一度押すと、フォーカスを入れる。
    ///
    /// 検索欄を閉じる動きの途中に押したときに、閉じ終えてからフォーカスを入れることは、テストでは確かめずシミュレーターで確かめる。
    /// 検索欄の開閉の動きは、窓の時間を止めて進めても終わらず（`LayerClock.runUntilIdle()`のあとも`transitionCoordinator`が残る）、
    /// 実際の時間で待っても、テスト全体を走らせて負荷がかかると終わらないことがあり、閉じ終えるのを待てないため。
    /// ここでは開いたときのフォーカスを止め、開閉の動きを待たずに確かめる。
    @Test func reselectingSearchTabFocusesSearchField() async throws {
        let search = SearchViewController()
        search.focusesOnAppear = false
        let window = try Self.window(showing: search)
        defer { window.isHidden = true }
        let navigation = try #require(search.navigationController)
        let field = try #require(search.navigationItem.searchController).searchBar.searchTextField
        try await waitUntil { search.viewIfLoaded?.window != nil && !search.isBeingPresented && navigation.transitionCoordinator == nil }
        #expect(!field.isFirstResponder)

        TabReselectionDelegate.reselectRoot(of: navigation)

        #expect(field.isFirstResponder)
    }

    /// 検索欄にフォーカスがある間に行とボタンのないところを押すと、キーボードだけを閉じ、検索欄と打った語は残す。ボタンや一覧にない行を押したときと、フォーカスがないときは閉じない。見出しの行はUIで確かめる。
    @Test func tappingEmptySpaceDismissesOnlyKeyboard() async throws {
        let search = SearchViewController()
        let window = try Self.window(showing: search)
        defer { window.isHidden = true }
        let searchController = try #require(search.navigationItem.searchController)
        let field = searchController.searchBar.searchTextField
        try await waitUntil { field.isFirstResponder }
        searchController.searchBar.text = "scia"
        let button = UIButton()
        search.view.addSubview(button)
        let cellContent = UIView()
        let cell = UICollectionViewCell()
        cell.contentView.addSubview(cellContent)
        search.view.addSubview(cell)

        #expect(search.dismissesKeyboard(touching: search.view))
        #expect(!search.dismissesKeyboard(touching: button))
        #expect(!search.dismissesKeyboard(touching: cellContent))

        search.dismissKeyboard()

        #expect(!field.isFirstResponder)
        #expect(searchController.isActive)
        #expect(searchController.searchBar.text == "scia")
        #expect(!search.dismissesKeyboard(touching: search.view))
    }

    private static func window(showing search: SearchViewController) throws -> UIWindow {
        let window = try makeWindow()
        show(search, in: window)
        return window
    }

    private static func makeWindow() throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "テストのホストアプリにウィンドウシーンがありません"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        return window
    }

    private static func show(_ search: SearchViewController, in window: UIWindow) {
        window.rootViewController = UINavigationController(rootViewController: search)
        window.makeKeyAndVisible()
        search.loadViewIfNeeded()
    }
}
