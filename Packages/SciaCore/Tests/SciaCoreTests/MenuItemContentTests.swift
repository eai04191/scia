@testable import SciaCore
import Testing

/// 長押しのメニューの項目が、共通の項目と正しくつながっていることを確かめる。
@MainActor
struct MenuItemContentTests {
    /// 共通の項目につないだ項目の、保存に使う名前と、つないだ共通の項目の名前。取り違えてつなぐと、2つが食い違う。
    private func mismatches<Item: MenuItemKind & MenuItemContentProviding>(_: Item.Type) -> [String] {
        Item.allCases.compactMap { item in
            guard let action = item.urlAction, "\(action)" != item.rawValue else { return nil }
            return "\(item.rawValue) → \(action)"
        }
    }

    @Test func urlItemsAreConnectedToTheSameNamedSharedItem() {
        #expect(mismatches(StatusMenuItem.self).isEmpty)
        #expect(mismatches(UserMenuItem.self).isEmpty)
        #expect(mismatches(LinkMenuItem.self).isEmpty)
        #expect(mismatches(HashtagMenuItem.self).isEmpty)
        #expect(mismatches(MediaMenuItem.self).isEmpty)
    }

    /// リンクのメニューの独自の項目は、組む処理を持つ「プロフィールとして開く」と「カスタマイズ」だけにする。ほかを足したら、組む処理を足してからここに加える。
    /// ハッシュタグのメニューは、独自の項目を`default`のない分岐で組むので、足し忘れはコンパイラが止める。
    @Test func linkMenuHasOnlyHandledOwnItems() {
        #expect(LinkMenuItem.allCases.filter { $0.urlAction == nil } == [.openAsProfile, .customize])
    }

    /// 共通の項目の名前はどのメニューでも同じ。
    @Test func sharedItemsHaveTheSameTitle() {
        #expect(StatusMenuItem.openInBrowser.title == "ブラウザで開く")
        #expect(HashtagMenuItem.openInBrowser.title == "ブラウザで開く")
    }
}
