import SciaCore
import Testing
import UIKit

/// メニューや並びの画面に出す項目の記号が、iOSにある記号であることを確かめる。
/// `UIImage(systemName:)`は、ない名前を渡してもエラーにならずnilを返し、アイコンのない行を黙って描くため。
@MainActor
struct MenuItemSymbolTests {
    /// 項目の型のすべての項目のうち、記号を作れないもの。
    private func missingSymbols<Item: MenuItemKind & MenuItemPresentable>(_: Item.Type) -> [String] {
        missingSymbols(Item.allCases)
    }

    private func missingSymbols<Item: MenuItemKind & MenuItemPresentable>(_ items: some Sequence<Item>) -> [String] {
        items.compactMap { item in
            UIImage(systemName: item.symbolName) == nil ? "\(item.rawValue): \(item.symbolName)" : nil
        }
    }

    /// 並びを設定で変えられるメニューの項目の型。どれも並びの画面に項目の記号を出し、メニューにも同じ記号を出す。
    @Test func everyItemHasASymbol() {
        #expect(missingSymbols(StatusMenuItem.self) == [])
        #expect(missingSymbols(UserMenuItem.self) == [])
        #expect(missingSymbols(LinkMenuItem.self) == [])
        #expect(missingSymbols(ExternalPostMenuItem.self) == [])
        #expect(missingSymbols(ProfileTextMenuItem.self) == [])
        #expect(missingSymbols(HashtagMenuItem.self) == [])
        #expect(missingSymbols(ReactionMenuItem.self) == [])
        #expect(missingSymbols(MediaMenuItem.self) == [])
        #expect(missingSymbols(PostActionBarItem.self) == [])
        #expect(missingSymbols(ComposeToolItem.self) == [])
    }

    /// タブの並びも、同じ並びの画面と切り替えタブのメニューに記号を出す。使う人が足すタブ（リスト、ハッシュタグ、プロフィール）は`allCases`に入らないので、種類ごとに1つずつ足して確かめる。
    @Test func everyTabHasASymbol() {
        let added: [TabItem] = [
            .list(id: "1", title: "リスト"),
            .hashtag(name: "scia"),
            .accountHashtag(accountID: "1", acct: "scia", name: "scia"),
            .profile(accountID: "1", acct: "scia"),
        ]
        #expect(missingSymbols(TabItem.allCases + added) == [])
    }
}
