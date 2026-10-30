import Foundation
import SciaCore
import Testing

/// メニューの木の組み方と、タップや長押しに割り当てた1項目の行い方を確かめる。決まりはdocs/menus.mdとdocs/object-actions.mdにある。
@MainActor
struct MenuNodeTests {
    /// 項目の名前。まとまりは`|`で区切り、横並びのまとまりは`=`で始め、サブメニューは`名前[中身]`、開いてから読む項目は`…`で表す。
    static func describe<C>(_ nodes: [MenuNode<C>]) -> String {
        nodes.map { node in
            switch node.content {
            case .group(let children, let isRow): (isRow ? "=" : "") + children.map { describe([$0]) }.joined(separator: ",")
            case .submenu(let children): "\(node.title)[\(children.map { describe([$0]) }.joined(separator: ","))]"
            case .deferred: "…"
            case .action: node.title + (node.isEnabled ? "" : "(押せない)") + (node.isSelected ? "✓" : "") + (node.isDestructive ? "!" : "")
            }
        }.joined(separator: "|")
    }

    /// 区切り線で分けたまとまりごとに並べ、「その他」の中身はサブメニューにする。中身のないまとまりと「その他」は出さない。
    @Test func groupsBecomeInlineGroupsAndMoreSubmenu() {
        let layout = MenuLayout<LinkMenuItem>(elements: [
            .rowSeparator, .item(.openInBrowser, isVisible: true), .item(.share, isVisible: true),
            .separator, .item(.copyLink, isVisible: true),
            .more, .item(.openAsProfile, isVisible: true), .item(.openInDefaultBrowser, isVisible: true), .item(.openInAppSafari, isVisible: true),
        ])
        let nodes = layout.groups.nodes { item -> [MenuNode<Int>] in item == .copyLink ? [] : [.action(item.title, 1)] }

        #expect(Self.describe(nodes) == "=ブラウザで開く,共有|その他[プロフィールとして開く,既定のブラウザで開く,アプリ内のSafariで開く]")

        let mainOnly = layout.groups.nodes { item -> [MenuNode<Int>] in [.openInBrowser].contains(item) ? [.action(item.title, 1)] : [] }
        #expect(Self.describe(mainOnly) == "=ブラウザで開く")
    }

    /// URLの項目は、URLがないか、選んだ場所で開けなければ押せない。
    @Test func urlItemsAreDisabledWithoutURLOrBrowser() throws {
        let page = try #require(URL(string: "https://example.social/@alice/1"))
        let mail = try #require(URL(string: "mailto:alice@example.social"))

        #expect(URLMenuAction.copyLink.node(url: page, linkBrowser: .inApp).command == .copy(page))
        #expect(URLMenuAction.share.node(url: nil, linkBrowser: .inApp).isEnabled == false)
        #expect(URLMenuAction.openInDefaultBrowser.node(url: page, linkBrowser: .inApp).command == .open(page, .external))
        #expect(URLMenuAction.openInAppSafari.node(url: mail, linkBrowser: .inApp).isEnabled == false)
        #expect(URLMenuAction.share.node(title: "@aliceを共有", url: page, linkBrowser: .inApp).title == "@aliceを共有")
    }

    /// 1項目だけの並びで組んだメニューは、押せる項目が1つならそれを行い、押せなければ理由を添えて知らせ、サブメニューが1つなら中身を出す。
    @Test func singleItemOutcome() {
        let enabled = MenuNode<Int>.submenu("", [.group([.action("返信", 1)])])
        let disabled = MenuNode<Int>.submenu("", [.group([.action("編集", subtitle: "締め切りまで5分を切った投票は編集できません", isEnabled: false, 2)])])
        let submenu = MenuNode<Int>.submenu("", [.group([.submenu("@alice", [.action("プロフィール", 3)])])])
        let deferred = MenuNode<Int>.submenu("", [.group([.deferred { [] }])])

        guard case .perform(1) = MenuItemOutcome(singleItemMenu: enabled) else { Issue.record(); return }
        guard case .unavailable(let reason) = MenuItemOutcome(singleItemMenu: disabled) else { Issue.record(); return }
        #expect(reason == "締め切りまで5分を切った投票は編集できません")
        guard case .submenu(let node) = MenuItemOutcome(singleItemMenu: submenu) else { Issue.record(); return }
        #expect(node.title == "@alice")
        #expect(MenuItemOutcome(singleItemMenu: deferred).isAvailable)
        #expect(!MenuItemOutcome<Int>(singleItemMenu: nil).isAvailable)
        #expect(!MenuItemOutcome(singleItemMenu: MenuNode<Int>.submenu("", [])).isAvailable)
    }

    /// ほかのメニューに入れるときは、開いてから読む中身も含めて操作を包む。
    @Test func mapWrapsDeferredChildren() async {
        let node = MenuNode<Int>.deferred { [.action("a", 1)] }.map { "\($0)" }
        guard case .deferred(let load) = node.content else { Issue.record(); return }
        #expect(await load().first?.command == "1")
    }
}
