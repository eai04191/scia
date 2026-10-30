import SciaCore
import Testing
import UIKit
@testable import Scia

/// SciaCoreで組んだメニューの木を、UIKitのメニューに描くことを確かめる。何をどの順に出すかは、SciaCoreのテストで確かめる。
@MainActor
struct MenuRendererTests {
    /// まとまりは見出しのないメニューにし、横並びのまとまりは中くらいの大きさで並べる。押せない項目、取り消せない操作、選んでいる状態を印にし、押すと操作を渡す。
    @Test func rendersNodesAsUIKitMenu() throws {
        var performed: [Int] = []
        let renderer = MenuRenderer<Int> { performed.append($0) }
        let root = MenuNode<Int>.submenu("見出し", [
            .group([.action("返信", icon: .symbol("arrowshape.turn.up.left"), 1)], isRow: true),
            .group([
                .action("削除", isDestructive: true, 2),
                .action("編集", subtitle: "理由", isEnabled: false, 3),
                .action("投稿を通知", isSelected: true, 4),
            ]),
            .submenu("その他", icon: .symbol("ellipsis.circle"), [.deferred { [] }]),
        ])

        let menu = renderer.menu(root)

        #expect(menu.title == "見出し")
        let row = try #require(menu.children[0] as? UIMenu)
        #expect(row.options.contains(.displayInline))
        #expect(row.preferredElementSize == .medium)
        let reply = try #require(row.children.first as? UIAction)
        #expect(reply.image != nil)
        let group = try #require(menu.children[1] as? UIMenu)
        #expect(group.preferredElementSize != .medium)
        let actions = group.children.compactMap { $0 as? UIAction }
        #expect(actions.map(\.title) == ["削除", "編集", "投稿を通知"])
        #expect(actions[0].attributes == .destructive)
        #expect(actions[1].attributes == .disabled)
        #expect(actions[1].subtitle == "理由")
        #expect(actions[2].state == .on)
        let more = try #require(menu.children[2] as? UIMenu)
        #expect(!more.options.contains(.displayInline))
        #expect(more.children.first is UIDeferredMenuElement)

        reply.performWithSender(nil, target: nil)
        #expect(performed == [1])
    }

    /// 人のアイコンやカスタム絵文字は、描く側が画像にする。出せなければ記号を出す。
    @Test func customIconFallsBackToSymbol() throws {
        let alice = Account(id: "2", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)
        let image = UIImage()
        let withImage = MenuRenderer<Int>(perform: { _ in }, customIcon: { _ in image })
        let without = MenuRenderer<Int>(perform: { _ in })

        #expect(withImage.image(.avatar(.user(.account(alice)), fallbackSymbol: "person.crop.circle")) === image)
        #expect(without.image(.avatar(.user(.account(alice)), fallbackSymbol: "person.crop.circle")) != nil)
        #expect(without.image(.avatar(.user(.account(alice)), fallbackSymbol: nil)) == nil)
    }
}
