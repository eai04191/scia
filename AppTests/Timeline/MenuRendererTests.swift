import SciaCore
import Testing
import UIKit
@testable import Scia

/// SciaCoreで組んだメニューのツリーを、UIKitのメニューに描くことを確かめる。何をどの順に出すかは、SciaCoreのテストで確かめる。
@MainActor
@Suite(.failureState)
struct MenuRendererTests {
    /// グループは見出しのないメニューにし、横並びのグループは選んだ大きさで並べる。無効な項目、取り消せない操作、選んでいる状態を、項目の属性とチェックマークで示し、選択すると操作を渡す。
    @Test func rendersNodesAsUIKitMenu() throws {
        var performed: [Int] = []
        let renderer = MenuRenderer<Int> { performed.append($0) }
        let root = MenuNode<Int>.submenu("見出し", [
            .group([.action("返信", icon: .symbol("arrowshape.turn.up.left"), 1)], row: .medium),
            .group([
                .action("削除", isDestructive: true, 2),
                .action("編集", subtitle: "理由", isEnabled: false, 3),
                .action("投稿を通知", isSelected: true, 4),
            ]),
            .submenu("その他", icon: .symbol("ellipsis.circle"), [.deferred { [] }]),
            .group([.action("共有", subtitle: "補足", 5), .submenu("送る", subtitle: "補足", []), .action("3", 6), .action("4", 7), .action("言語", subtitle: "日本語", 8)], row: .small),
        ])

        let menu = renderer.menu(root)

        #expect(menu.title == "見出し")
        let row = try #require(menu.children[0] as? UIMenu)
        #expect(row.options.contains(.displayInline))
        #expect(row.preferredElementSize == .medium)
        let reply = try #require(row.children.first as? UIAction)
        #expect(reply.image != nil)
        let group = try #require(menu.children[1] as? UIMenu)
        #expect(group.preferredElementSize != .medium && group.preferredElementSize != .small)
        // 横並びのグループで横に並ぶ項目は、サブタイトルを出さない。横に並ぶ数を超えてふだんの行で出る項目には残す。
        let small = try #require(menu.children[3] as? UIMenu)
        #expect(small.preferredElementSize == .small)
        #expect(small.children.map(\.subtitle) == [nil, nil, nil, nil, "日本語"])
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
