import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing

/// ナビゲーションバーのボタンから出すメニューで、中身を読む項目を含むサブメニューを、読み終えてから出す行にすることを確かめる。決まりはdocs/menus.mdの「メニューの単位」にある。
@MainActor
struct BarMenuTests {
    private func describe(_ nodes: [MenuNode<Int>]) -> String {
        MenuNodeTests.describe(nodes)
    }

    private func root(_ children: [MenuNode<Int>]) -> MenuNode<Int> {
        .submenu("", children)
    }

    /// 最初の段の`index`番目の、読み込み中の行を読む。読み込み中の行でなければ記録してnil。
    private func load(_ nodes: [MenuNode<Int>], at index: Int) async -> [MenuNode<Int>]? {
        guard case .deferred(let load) = nodes[index].content else {
            Issue.record("\(index)番目が読み込み中の行ではありません: \(describe(nodes))")
            return nil
        }
        return await load()
    }

    /// 中身を読む項目を含むサブメニューは、行ごと読み込み中の行にし、読むと、名前やアイコンを保ったまま、中身を読み終えたサブメニューを返す。
    /// サブメニューの中のサブメニューと区切り線のまとまりにある項目も読み終え、中身が空になったまとまりは除く。
    @Test func submenuWithDeferredContentLoadsBeforeShowing() async throws {
        let menu = root([
            .action("共有", 1),
            .submenu("別のアカウントで", subtitle: "説明", icon: .symbol("person.2"), [
                .submenu("@bob", [.deferred { [.action("フォロー", 2)] }]),
                .group([.deferred { [] }]),
                .group([.action("ミュート", 3), .deferred { [.action("ブロック", 4)] }]),
            ]),
        ]).loadingSubmenusBeforeShowing()

        #expect(describe(menu.children) == "共有|…")
        let loaded = try #require(await load(menu.children, at: 1))
        #expect(describe(loaded) == "別のアカウントで[@bob[フォロー],ミュート,ブロック]")
        #expect(loaded.first?.subtitle == "説明")
        #expect(loaded.first?.icon?.symbolName == "person.2")
    }

    /// 中身を読む項目を含まないサブメニューは、そのまま出す。最初の段の読み込み中の行と区切り線のまとまりの中は、そのまま最初の段に出す。
    /// 最初の段の読み込み中の行が読んだ中身も、同じく組み替える。
    @Test func onlySubmenusWithDeferredContentChange() async throws {
        let menu = root([
            .submenu("ミュート", [.action("5分", 1)]),
            .group([.submenu("その他", [.deferred { [.action("ブロック", 2)] }])]),
            .deferred { [.action("フォロー", 3), .submenu("@bob", [.deferred { [.action("メンション", 4)] }])] },
        ]).loadingSubmenusBeforeShowing()

        #expect(describe(menu.children) == "ミュート[5分]|…|…")
        guard case .group(let group, _) = menu.children[1].content else {
            Issue.record("まとまりではありません")
            return
        }
        #expect(describe(try #require(await load(group, at: 0))) == "その他[ブロック]")
        let deferred = try #require(await load(menu.children, at: 2))
        #expect(describe(deferred) == "フォロー|…")
        #expect(describe(try #require(await load(deferred, at: 1))) == "@bob[メンション]")
    }

    /// サブメニューの中の読む項目は同時に読み、元の並びの順で返す。ほかのアカウントごとに相手を探すときに、待つ時間が足し上がらないため。
    @Test func deferredContentLoadsConcurrently() async throws {
        let first = Gate()
        let second = Gate()
        let menu = root([
            .submenu("別のアカウントで", [
                .submenu("@bob", [.deferred {
                    try? await first.wait()
                    return [.action("1", 1)]
                }]),
                .submenu("@carol", [.deferred {
                    try? await second.wait()
                    return [.action("2", 2)]
                }]),
            ]),
        ]).loadingSubmenusBeforeShowing()

        // メニューの木は送れないので、読んだ中身を名前の並びにして受け取る。
        let loading = Task { await load(menu.children, at: 0).map(describe) }
        // 1つ目を開く前に、2つ目も読み始めている。
        try await waitUntil { first.waiterCount == 1 && second.waiterCount == 1 }
        second.open()
        first.open()
        #expect(await loading.value == "別のアカウントで[@bob[1],@carol[2]]")
    }
}
