import SciaCore
import UIKit

@MainActor
extension MenuLayout.Groups {
    /// まとまりごとに区切り線で分けて並べ、「その他」の中身はサブメニューにする。中身のないまとまりと「その他」は出さない。
    func menuElements(_ elements: (Item) -> [UIMenuElement]) -> [UIMenuElement] {
        func inline(_ groups: [[Item]]) -> [UIMenuElement] {
            groups.compactMap { group in
                let children = group.flatMap(elements)
                return children.isEmpty ? nil : UIMenu(options: .displayInline, children: children)
            }
        }
        let main = inline(main)
        let more = inline(more)
        guard !more.isEmpty else { return main }
        return main + [UIMenu(title: "その他", image: UIImage(systemName: "ellipsis.circle"), children: more)]
    }
}

/// 長押しのメニューの項目の中身。名前、印、説明はここから決める。
enum MenuItemContent {
    /// URLに対する共通の項目。名前、印、説明、押したときの動きは共通の項目のものを使う。
    /// - Parameter noteSuffix: このメニューに固有の決まり。共通の説明の後ろに書き足す。
    case url(URLMenuAction, noteSuffix: String? = nil)
    /// このメニューだけの項目。押したときの動きは、メニューを組む側で決める。
    case own(title: String, symbolName: String, note: String? = nil)
}

/// 中身から名前、印、説明を決める項目。項目の種類ごとに、`content`の分岐を1つだけ書く。
/// 分岐に`default`を書かない。項目を足したときに、共通の項目につなぐか、独自の項目にするかをコンパイラに確かめさせるため。
protocol MenuItemContentProviding: MenuItemPresentable {
    var content: MenuItemContent { get }
}

extension MenuItemContentProviding {
    var title: String {
        switch content {
        case .url(let action, _): action.title
        case .own(let title, _, _): title
        }
    }

    var note: String? {
        switch content {
        case .url(let action, let suffix):
            let parts = [action.note, suffix].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: "。")
        case .own(_, _, let note):
            return note
        }
    }

    var symbolName: String {
        switch content {
        case .url(let action, _): action.symbolName
        case .own(_, let symbolName, _): symbolName
        }
    }

    var image: UIImage? { UIImage(systemName: symbolName) }

    /// 共通の項目なら、その項目。
    var urlAction: URLMenuAction? {
        if case .url(let action, _) = content { action } else { nil }
    }
}

extension StatusMenuItem: MenuItemContentProviding {
    var content: MenuItemContent {
        switch self {
        case .reply: .own(title: "返信", symbolName: "arrowshape.turn.up.left")
        case .favourite: .own(title: "お気に入り", symbolName: "star")
        case .reblog: .own(title: "ブースト", symbolName: "arrow.2.squarepath")
        case .copyLink: .url(.copyLink)
        case .copyText: .own(title: "テキストをコピー", symbolName: "doc.on.doc", note: "本文のある投稿でだけ出ます")
        case .share: .url(.share)
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .editHistory: .own(title: "編集履歴", symbolName: "clock.arrow.circlepath", note: "編集された投稿でだけ出ます")
        case .edit: .own(title: "編集", symbolName: "pencil", note: "自分の投稿でだけ出ます")
        case .delete: .own(title: "削除", symbolName: "trash", note: "自分の投稿でだけ出ます")
        case .hideMedia: .own(title: "メディアを隠す", symbolName: "eye.slash", note: "表示している添付ファイルがある投稿でだけ出ます")
        case .systemTranslate: .own(title: "翻訳", symbolName: "translate", note: "本文のある投稿でだけ出ます")
        case .notifyingUser: .own(title: "通知したユーザー", symbolName: "bell", note: "通知でだけ出ます")
        case .author: .own(title: "投稿したユーザー", symbolName: "person.crop.circle")
        case .booster: .own(title: "ブーストしたユーザー", symbolName: "person.crop.circle.badge.plus", note: "ブーストでだけ出ます")
        case .mentionedUsers: .own(title: "メンションされたユーザー", symbolName: "at")
        }
    }
}

extension UserMenuItem: MenuItemContentProviding {
    var content: MenuItemContent {
        switch self {
        case .profile: .own(title: "プロフィール", symbolName: "person.crop.circle")
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        }
    }
}

extension LinkMenuItem: MenuItemContentProviding {
    var content: MenuItemContent {
        switch self {
        case .openInBrowser: .url(.openInBrowser, noteSuffix: "リンクをタップしたときと同じです")
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        // 投稿とハッシュタグのURLはMastodonのhttpsのページだが、本文のリンクはほかのスキームもありうる。
        case .openInAppSafari: .url(.openInAppSafari, noteSuffix: "httpとhttpsのリンクでだけ押せます")
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        }
    }
}

extension HashtagMenuItem: MenuItemContentProviding {
    var content: MenuItemContent {
        switch self {
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        }
    }
}

/// 投稿のメニューの中で、ユーザーのメニューを出す相手。メンションはアカウントの全体を持たないため、IDでプロフィールを開く。
enum MenuUser {
    case account(Account)
    case mention(Mention)

    var id: String {
        switch self {
        case .account(let account): account.id
        case .mention(let mention): mention.id
        }
    }

    var acct: String {
        switch self {
        case .account(let account): account.acct
        case .mention(let mention): mention.acct
        }
    }

    /// プロフィールのページのURL。
    var url: URL? {
        switch self {
        case .account(let account): account.url
        case .mention(let mention): mention.url
        }
    }
}
