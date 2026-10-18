import SciaCore
import UIKit

/// メニューと、並びの設定画面に出す、項目の名前と印。
extension StatusMenuItem {
    var title: String {
        switch self {
        case .reply: "返信"
        case .favourite: "お気に入り"
        case .reblog: "ブースト"
        case .copyLink: "リンクをコピー"
        case .share: "共有"
        case .openInBrowser: "ブラウザで開く"
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
        case .copyLink: "link"
        case .share: "square.and.arrow.up"
        case .openInBrowser: "safari"
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
        }
    }

    var note: String? { nil }

    var symbolName: String {
        switch self {
        case .profile: "person.crop.circle"
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
}
