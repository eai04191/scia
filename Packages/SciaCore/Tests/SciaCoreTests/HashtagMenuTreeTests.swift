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

    private func muteActions(known: Bool?, recorder: Recorder = Recorder(), load: @escaping @MainActor (String) async throws -> Bool = { _ in false }) -> HashtagMenuActions {
        HashtagMenuActions(mute: HashtagMuteActions(known: { _ in known }, refresh: { recorder.refreshes += 1 }, load: load, mute: { _, _ in }, unmute: { _ in }))
    }

    /// 見出しに`#名前`を置き、ほかのサーバーのユーザーの「@名前の投稿」には、サーバー名をサブタイトルに添える。URLが分からなければ、URLの項目を押せない。
    @Test func headingAndItems() throws {
        let tree = HashtagMenuTree(name: "cat", url: nil, account: alice, linkBrowser: .inApp, actions: nil)
        let menu = try #require(tree.menu(groups: all))

        #expect(menu.title == "#cat")
        #expect(menu.icon == nil)
        #expect(MenuNodeTests.describe(menu.children) == "すべての投稿,@aliceの投稿,ブラウザで開く(押せない),デフォルトのブラウザで開く(押せない),アプリ内のSafariで開く(押せない),リンクをコピー(押せない),共有(押せない),カスタマイズ")
        #expect(menu.children.first?.children[1].subtitle == "remote.example")
        // 投稿のメニューの中に置くときは、「ハッシュタグ」のアイコンを付ける。
        #expect(tree.submenu(groups: all)?.icon?.symbolName == "number")
    }

    /// 「ミュート」は、フィルターを覚えていれば、その場でミュートしているかを決め、読み込み中の行を出さない。
    /// まだ読めていなければ、読んでから中身を決める。どちらでも、メニューを組むたびにフィルターを読み直す。
    @Test func muteUsesKnownFiltersAndRefreshes() async throws {
        let recorder = Recorder()
        func describe(_ known: Bool?) throws -> String {
            let tree = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, actions: muteActions(known: known, recorder: recorder))
            return MenuNodeTests.describe(try #require(tree.menu(groups: .single(.mute))).children)
        }

        #expect(try describe(true) == "ミュートを解除")
        #expect(try describe(false) == "ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日]")
        #expect(try describe(nil) == "…")
        #expect(recorder.refreshes == 3)
    }

    /// 読めなかったら、押せない行で知らせる。
    @Test func muteLoadFailureIsShownAsDisabledRow() async throws {
        let tree = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, actions: muteActions(known: nil) { _ in throw URLError(.notConnectedToInternet) })
        let menu = try #require(tree.menu(groups: .single(.mute)))
        guard case .deferred(let load) = try #require(menu.flattenedChildren.first).content else {
            Issue.record("読み込み中の行になっていません")
            return
        }

        #expect(MenuNodeTests.describe(await load()) == "ミュートを読み込めませんでした(押せない)")
    }

    /// 「投稿欄に追加」は、投稿欄に入れる手段を渡したときだけ出す。「別のアカウントで」のハッシュタグのメニューでは渡さない。
    @Test func addToComposeNeedsAction() throws {
        let without = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, actions: HashtagMenuActions(mute: nil))
        #expect(without.menu(groups: .single(.addToCompose)) == nil)

        let with = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, actions: HashtagMenuActions(mute: nil, addToCompose: { _ in }))
        let item = try #require(with.menu(groups: .single(.addToCompose))?.flattenedChildren.first)
        #expect(item.title == "投稿欄に追加")
        #expect(item.command == .addToCompose)
    }

    private func featureActions(known: Bool?, recorder: Recorder = Recorder(), load: @escaping @MainActor (String) async throws -> Bool = { _ in false }) -> HashtagMenuActions {
        HashtagMenuActions(mute: nil, feature: HashtagToggleActions(known: { _ in known }, refresh: { recorder.refreshes += 1 }, load: load, turnOn: { _ in }, turnOff: { _ in }))
    }

    /// 「プロフィールで紹介する」は、覚えている自分の注目のハッシュタグで、その場で載せているかを決め、載せていれば「プロフィールから外す」にする。
    /// まだ読めていなければ、読んでから決める。どちらでも、メニューを組むたびに読み直す。
    @Test func featureUsesKnownTagsAndRefreshes() async throws {
        let recorder = Recorder()
        func describe(_ known: Bool?) throws -> String {
            let tree = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, actions: featureActions(known: known, recorder: recorder))
            return MenuNodeTests.describe(try #require(tree.menu(groups: .single(.feature))).children)
        }

        #expect(try describe(true) == "プロフィールから外す")
        #expect(try describe(false) == "プロフィールで紹介する")
        #expect(try describe(nil) == "…")
        #expect(recorder.refreshes == 3)
    }

    /// 読んでから決めるときは、読んだ結果で載せているかを決める。読めなかったら、押せない行で知らせる。
    @Test func featureDecidesAfterLoadingOrShowsFailure() async throws {
        func loaded(_ load: @escaping @MainActor (String) async throws -> Bool) async throws -> String {
            let tree = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, actions: featureActions(known: nil, load: load))
            let menu = try #require(tree.menu(groups: .single(.feature)))
            guard case .deferred(let load) = try #require(menu.flattenedChildren.first).content else {
                Issue.record("読み込み中の行になっていません")
                return ""
            }
            return MenuNodeTests.describe(await load())
        }

        #expect(try await loaded { _ in true } == "プロフィールから外す")
        #expect(try await loaded { _ in throw URLError(.notConnectedToInternet) } == "注目のハッシュタグを読み込めませんでした(押せない)")
    }

    private func followActions(known: Bool?, recorder: Recorder = Recorder(), load: @escaping @MainActor (String) async throws -> Bool = { _ in false }) -> HashtagMenuActions {
        HashtagMenuActions(mute: nil, follow: HashtagToggleActions(known: { _ in known }, refresh: { recorder.refreshes += 1 }, load: load, turnOn: { _ in }, turnOff: { _ in }))
    }

    /// 「フォロー」は、覚えているフォローしているハッシュタグで、その場でフォローしているかを決め、フォローしていれば「フォローを外す」にする。
    /// まだ読めていなければ、読んでから決め、読めなかったら押せない行で知らせる。どちらでも、メニューを組むたびに読み直す。
    @Test func followUsesKnownTagsAndRefreshes() async throws {
        let recorder = Recorder()
        func menu(_ known: Bool?, load: @escaping @MainActor (String) async throws -> Bool = { _ in false }) throws -> MenuNode<HashtagMenuCommand> {
            let tree = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, actions: followActions(known: known, recorder: recorder, load: load))
            return try #require(tree.menu(groups: .single(.follow)))
        }

        #expect(MenuNodeTests.describe(try menu(true).children) == "フォローを外す")
        #expect(MenuNodeTests.describe(try menu(false).children) == "フォロー")
        #expect(MenuNodeTests.describe(try menu(nil).children) == "…")
        #expect(recorder.refreshes == 3)

        guard case .deferred(let failing) = try #require(try menu(nil) { _ in throw URLError(.notConnectedToInternet) }.flattenedChildren.first).content else {
            Issue.record("読み込み中の行になっていません")
            return
        }
        #expect(MenuNodeTests.describe(await failing()) == "フォローしているハッシュタグを読み込めませんでした(押せない)")
    }

    /// 押したときに送る操作は、フォローしているかで決まる。
    @Test func followCommands() throws {
        func command(_ known: Bool) throws -> HashtagMenuCommand? {
            let tree = HashtagMenuTree(name: "cat", url: nil, account: nil, linkBrowser: .inApp, actions: followActions(known: known))
            return try #require(tree.menu(groups: .single(.follow))).flattenedChildren.first?.command
        }

        #expect(try command(false) == .follow)
        #expect(try command(true) == .unfollow)
    }

    /// 載せているかは、サーバーと同じ決まりでそろえた名前で比べる。
    @Test func featuredTagsMatchNormalizedName() {
        let tags = [FeaturedTag(id: "1", name: "Cat", statusesCount: 3)]

        #expect(tags.first(named: "cat")?.id == "1")
        #expect(tags.first(named: "dog") == nil)
    }

    /// フォローしているかも、サーバーと同じ決まりでそろえた名前で比べる。
    @Test func followedTagsMatchNormalizedName() {
        let tags = [Hashtag(name: "Cat")]

        #expect(tags.contains(named: "ＣＡＴ"))
        #expect(!tags.contains(named: "dog"))
    }
}
