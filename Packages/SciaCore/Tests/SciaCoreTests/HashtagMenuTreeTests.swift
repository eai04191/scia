import Foundation
import SciaCore
import Testing

/// ハッシュタグのメニューの組み方を確かめる。決まりはdocs/menus.mdの「ハッシュタグのメニュー」にある。
@MainActor
struct HashtagMenuTreeTests {
    private let all = MenuLayout<HashtagMenuItem>(elements: HashtagMenuItem.allCases.map { .item($0, isVisible: true) } + [.more]).groups
    private let alice = Account(id: "2", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil)

    @MainActor
    private final class Recorder {
        var refreshes = 0
    }

    private func muteActions(known: Bool?, recorder: Recorder = Recorder(), load: @escaping @MainActor (String) async throws -> Bool = { _ in false }) -> HashtagMuteActions {
        HashtagMuteActions(known: { _ in known }, refresh: { recorder.refreshes += 1 }, load: load, mute: { _, _ in }, unmute: { _ in })
    }

    /// 見出しに`#名前`を置き、ほかのサーバーのユーザーの「@名前の投稿」には、サーバー名をサブタイトルに添える。URLが分からなければ、URLの項目を押せない。
    @Test func headingAndItems() throws {
        let tree = HashtagMenuTree(name: "cat", url: nil, account: alice, linkBrowser: .inApp, muteActions: nil)
        let menu = try #require(tree.menu(groups: all))

        #expect(menu.title == "#cat")
        #expect(menu.icon == nil)
        #expect(MenuNodeTests.describe(menu.children) == "すべての投稿,@aliceの投稿,ブラウザで開く(押せない),既定のブラウザで開く(押せない),アプリ内のSafariで開く(押せない),リンクをコピー(押せない),共有(押せない)")
        #expect(menu.children.first?.children[1].subtitle == "remote.example")
        // 投稿のメニューの中に置くときは、「ハッシュタグ」のアイコンを付ける。
        #expect(tree.submenu(groups: all)?.icon?.symbolName == "number")
    }

    /// 「ミュート」は、フィルターを覚えていれば、その場でミュートしているかを決め、読み込み中の行を出さない。
    /// まだ読めていなければ、読んでから中身を決める。どちらでも、メニューを組むたびにフィルターを読み直す。
    @Test func muteUsesKnownFiltersAndRefreshes() async throws {
        let recorder = Recorder()
        func describe(_ known: Bool?) throws -> String {
            let tree = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, muteActions: muteActions(known: known, recorder: recorder))
            return MenuNodeTests.describe(try #require(tree.menu(groups: .single(.mute))).children)
        }

        #expect(try describe(true) == "ミュートを解除")
        #expect(try describe(false) == "ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日]")
        #expect(try describe(nil) == "…")
        #expect(recorder.refreshes == 3)
    }

    /// 読めなかったら、押せない行で知らせる。
    @Test func muteLoadFailureIsShownAsDisabledRow() async throws {
        let tree = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, muteActions: muteActions(known: nil) { _ in throw URLError(.notConnectedToInternet) })
        let menu = try #require(tree.menu(groups: .single(.mute)))
        guard case .deferred(let load) = try #require(menu.flattenedChildren.first).content else {
            Issue.record("読み込み中の行になっていません")
            return
        }

        #expect(MenuNodeTests.describe(await load()) == "ミュートを読み込めませんでした(押せない)")
    }
}
