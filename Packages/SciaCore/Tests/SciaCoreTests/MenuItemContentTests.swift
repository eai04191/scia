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

    /// リンクのメニューの独自の項目は、組む処理を持つ「プロフィールとして開く」だけにする。ほかを足したら、組む処理を足してからここに加える。
    /// ハッシュタグのメニューは、独自の項目を`default`のない分岐で組むので、足し忘れはコンパイラが止める。
    @Test func linkMenuHasOnlyHandledOwnItems() {
        #expect(LinkMenuItem.allCases.filter { $0.urlAction == nil } == [.openAsProfile])
    }

    /// 共通の項目の名前と説明はどのメニューでも同じで、メニューに固有の決まりだけを書き足す。
    @Test func sharedItemsHaveTheSameTitleAndNote() {
        #expect(StatusMenuItem.openInBrowser.title == "ブラウザで開く")
        #expect(HashtagMenuItem.openInBrowser.title == "ブラウザで開く")
        #expect(StatusMenuItem.openInBrowser.note == "設定の開く場所で開きます")
        #expect(HashtagMenuItem.openInBrowser.note == "設定の開く場所で開きます")
        #expect(LinkMenuItem.openInBrowser.note == "設定の開く場所で開きます。リンクをタップしたときと同じです")
        #expect(StatusMenuItem.openInAppSafari.note == "設定の開く場所にかかわらず、アプリ内のSafariで開きます")
        #expect(LinkMenuItem.openInAppSafari.note == "設定の開く場所にかかわらず、アプリ内のSafariで開きます。httpとhttpsのリンクでだけ押せます")
        #expect(UserMenuItem.copyLink.note == nil)
    }
}
