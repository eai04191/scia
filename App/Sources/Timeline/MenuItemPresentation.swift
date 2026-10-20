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

/// メニューと、並びの設定画面に出す、項目の名前と印。
extension StatusMenuItem {
    var title: String {
        switch self {
        case .reply: "返信"
        case .favourite: "お気に入り"
        case .reblog: "ブースト"
        case .copyLink: URLMenuAction.copyLink.title
        case .share: URLMenuAction.share.title
        case .openInBrowser: URLMenuAction.openInBrowser.title
        case .editHistory: "編集履歴"
        case .edit: "編集"
        case .delete: "削除"
        case .hideMedia: "メディアを隠す"
        case .notifyingUser: "通知したユーザー"
        case .author: "投稿したユーザー"
        case .booster: "ブーストしたユーザー"
        case .mentionedUsers: "メンションされたユーザー"
        }
    }

    /// 設定画面で、名前の下に添える説明。
    var note: String? {
        switch self {
        case .editHistory: "編集された投稿でだけ出ます"
        case .edit, .delete: "自分の投稿でだけ出ます"
        case .hideMedia: "表示している添付ファイルがある投稿でだけ出ます"
        case .notifyingUser: "通知でだけ出ます"
        case .booster: "ブーストでだけ出ます"
        default: nil
        }
    }

    var symbolName: String {
        switch self {
        case .reply: "arrowshape.turn.up.left"
        case .favourite: "star"
        case .reblog: "arrow.2.squarepath"
        case .copyLink: URLMenuAction.copyLink.symbolName
        case .share: URLMenuAction.share.symbolName
        case .openInBrowser: URLMenuAction.openInBrowser.symbolName
        case .editHistory: "clock.arrow.circlepath"
        case .edit: "pencil"
        case .delete: "trash"
        case .hideMedia: "eye.slash"
        case .notifyingUser: "bell"
        case .author: "person.crop.circle"
        case .booster: "person.crop.circle.badge.plus"
        case .mentionedUsers: "at"
        }
    }

    var image: UIImage? { UIImage(systemName: symbolName) }
}

extension UserMenuItem {
    var title: String {
        switch self {
        case .profile: "プロフィール"
        case .copyLink: URLMenuAction.copyLink.title
        case .share: URLMenuAction.share.title
        }
    }

    var note: String? { nil }

    var symbolName: String {
        switch self {
        case .profile: "person.crop.circle"
        case .copyLink: URLMenuAction.copyLink.symbolName
        case .share: URLMenuAction.share.symbolName
        }
    }

    var image: UIImage? { UIImage(systemName: symbolName) }
}

extension LinkMenuItem {
    var title: String {
        switch self {
        case .open: "開く"
        case .openInBrowser: URLMenuAction.openInBrowser.title
        case .copyLink: URLMenuAction.copyLink.title
        case .share: URLMenuAction.share.title
        }
    }

    var note: String? {
        switch self {
        case .open: "リンクをタップしたときと同じく、設定の開く場所で開きます"
        case .openInBrowser: "開く場所の設定にかかわらず、既定のブラウザで開きます"
        default: nil
        }
    }

    var symbolName: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .openInBrowser: URLMenuAction.openInBrowser.symbolName
        case .copyLink: URLMenuAction.copyLink.symbolName
        case .share: URLMenuAction.share.symbolName
        }
    }

    var image: UIImage? { UIImage(systemName: symbolName) }
}

extension HashtagMenuItem {
    var title: String {
        switch self {
        case .openInBrowser: URLMenuAction.openInBrowser.title
        case .copyLink: URLMenuAction.copyLink.title
        case .share: URLMenuAction.share.title
        }
    }

    var note: String? { nil }

    var symbolName: String {
        switch self {
        case .openInBrowser: URLMenuAction.openInBrowser.symbolName
        case .copyLink: URLMenuAction.copyLink.symbolName
        case .share: URLMenuAction.share.symbolName
        }
    }

    var image: UIImage? { UIImage(systemName: symbolName) }
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
