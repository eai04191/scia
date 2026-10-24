import SciaCore
import UIKit

@MainActor
extension MenuLayout.Groups {
    /// まとまりごとに区切り線で分けて並べ、「その他」の中身はサブメニューにする。中身のないまとまりと「その他」は出さない。
    /// 横並びのまとまりは、アイコンと名前を縦に積んだ中くらいの大きさで横に並べる。横に並ぶのは3個までで、4個目からはその下にふだんの行として続く。
    func menuElements(_ elements: (Item) -> [UIMenuElement]) -> [UIMenuElement] {
        func inline(_ groups: [MenuLayout<Item>.Group]) -> [UIMenuElement] {
            groups.compactMap { group in
                let children = group.items.flatMap(elements)
                guard !children.isEmpty else { return nil }
                let menu = UIMenu(options: .displayInline, children: children)
                if group.isRow { menu.preferredElementSize = .medium }
                return menu
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
        case .bookmark: .own(title: "ブックマーク", symbolName: "bookmark")
        case .reblogWithVisibility: .own(title: "公開範囲を選んでブースト", symbolName: "arrow.2.squarepath", note: "ブーストしていない、公開かひかえめな公開の投稿でだけ出ます")
        case .pin: .own(title: "プロフィールに固定", symbolName: "pin", note: "ダイレクトではない自分の投稿でだけ出ます")
        case .muteConversation: .own(title: "会話をミュート", symbolName: "bell.slash", note: "自分の投稿、通知、自分へのメンションを含む投稿でだけ出ます")
        case .copyLink: .url(.copyLink)
        case .copyText: .own(title: "テキストをコピー", symbolName: "doc.on.doc", note: "本文のある投稿でだけ出ます")
        case .share: .url(.share)
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .editHistory: .own(title: "編集履歴", symbolName: "clock.arrow.circlepath", note: "編集された投稿でだけ出ます")
        case .favouritedBy: .own(title: "お気に入りした人", symbolName: "star.circle", note: "お気に入りされた投稿でだけ出ます")
        case .rebloggedBy: .own(title: "ブーストした人", symbolName: "arrow.2.squarepath.circle", note: "ブーストされた投稿でだけ出ます")
        case .edit: .own(title: "編集", symbolName: "pencil", note: "自分の投稿でだけ出ます")
        case .delete: .own(title: "削除", symbolName: "trash", note: "自分の投稿でだけ出ます")
        case .dismissNotification: .own(title: "通知を削除", symbolName: "xmark.bin", note: "通知でだけ出ます")
        case .hideMedia: .own(title: "メディアを隠す", symbolName: "eye.slash", note: "表示している添付ファイルがある投稿でだけ出ます")
        case .systemTranslate: .own(title: "翻訳", symbolName: "translate", note: "本文のある投稿でだけ出ます")
        case .notifyingUser: .own(title: "通知したユーザー", symbolName: "bell", note: "通知でだけ出ます")
        case .author: .own(title: "投稿したユーザー", symbolName: "person.crop.circle")
        case .booster: .own(title: "ブーストしたユーザー", symbolName: "person.crop.circle.badge.plus", note: "ブーストでだけ出ます")
        case .mentionedUsers: .own(title: "メンションされたユーザー", symbolName: "at")
        case .customEmojis: .own(title: "カスタム絵文字", symbolName: "face.smiling", note: "行にカスタム絵文字があるときだけ出ます。絵文字ごとに、画像のメディアのメニューを出します")
        }
    }
}

extension UserMenuItem: MenuItemContentProviding {
    var content: MenuItemContent {
        switch self {
        case .profile: .own(title: "プロフィール", symbolName: "person.crop.circle", note: "プロフィール画面では出ません")
        case .mention: .own(title: "メンション", symbolName: "square.and.pencil", note: "投稿欄のカーソルの位置に入れます")
        case .copyHandle: .own(title: "ハンドルをコピー", symbolName: "at", note: "サーバー名を付けた形でコピーします")
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .follow: .own(title: "フォロー", symbolName: "person.badge.plus", note: "フォロー中なら外し、リクエスト中なら取り消します。自分には出ません")
        case .showReblogs: .own(title: "ブーストを表示", symbolName: "arrow.2.squarepath", note: "フォローしている相手でだけ出ます")
        case .notify: .own(title: "投稿を通知", symbolName: "bell", note: "フォローしている相手でだけ出ます")
        case .mute: .own(title: "ミュート", symbolName: "speaker.slash", note: "期間を選んでミュートします。ミュート中なら解除します")
        case .block: .own(title: "ブロック", symbolName: "hand.raised", note: "ブロック中なら解除します")
        case .report: .own(title: "通報", symbolName: "flag", note: "投稿のメニューから開くと、その人の投稿なら添えます。自分には出ません")
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
        case .openAsProfile: .own(title: "プロフィールとして開く", symbolName: "person.crop.circle", note: "リンク先のプロフィールをサーバーで探して開きます。httpとhttpsのリンクでだけ押せます")
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        }
    }
}

extension HashtagMenuItem: MenuItemContentProviding {
    var content: MenuItemContent {
        switch self {
        case .timeline: .own(title: "すべての投稿", symbolName: "number", note: "ハッシュタグのタイムラインを開きます。ハッシュタグをタップしたときと同じです")
        case .accountStatuses: .own(title: "投稿したユーザーの投稿", symbolName: "person.crop.square", note: "このハッシュタグの付いた、投稿したユーザーの投稿を開きます。プロフィールではその人の投稿です。メニューでは「@名前の投稿」と出ます")
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

/// ユーザーのメニューの、メンション、ハンドルをコピー、関係の項目で使う相手。
enum UserMenuTarget {
    /// APIの`Account`や`mentions`から取ったIDと`acct`。そのまま使える。
    case account(id: String, acct: String)
    /// 本文や自己紹介のメンションのリンク。APIの`mentions`にないリンクでは、パーサーはリンクの文字列を`acct`の代わりにするが、
    /// Mastodonはほかのサーバーのユーザーでもリンクの文字列からサーバー名を省くため、そのままでは別のユーザーを指す。プロフィールのURLでアカウントを引いて`acct`を決める。
    /// - Parameter shownAcct: 見つからなかったときの知らせに出す、リンクの文字列から取った名前。
    case profileURL(URL, shownAcct: String)
}

/// ユーザーのメニューの、投稿欄とログイン中のサーバーに頼る項目（メンション、ハンドルをコピー、関係の項目）を組むもの。
/// 画面を組み立てる側が渡す。渡されていない画面では、これらの項目を出さない。
struct UserMenuActions {
    /// 投稿欄で、カーソルの位置に`@acct`を入れる。
    let mention: @MainActor (UserMenuTarget) -> Void
    /// サーバー名を付けた`@username@domain`の形でコピーし、コピーできたら`notify`を呼ぶ。
    let copyHandle: @MainActor (UserMenuTarget, _ notify: @escaping @MainActor () -> Void) -> Void
    /// 相手と自分の関係を読む。自分ならnil。
    let loadRelation: @MainActor (UserMenuTarget) async throws -> UserRelation?
    /// 関係の項目で選んだ変更を送る。取り消しにくい変更は、確かめてから送る。
    let changeRelation: @MainActor (UserRelationChange, UserRelation) -> Void
    /// 通報のシートを開く。投稿のメニューから開いたときは、添えられる相手の投稿のIDを渡す。
    let report: @MainActor (UserRelation, _ statusID: String?) -> Void
    /// 前に`loadAccount`で読んだアカウント。読んでいなければnil。
    let cachedAccount: @MainActor (String) -> Account?
    /// アカウントをIDで読む。メンションされたユーザーのように、アイコンのURLが手元にない相手のアイコンを出すのに使う。
    let loadAccount: @MainActor (String) async throws -> Account

    /// メンションとハンドルをコピーの項目。ほかの項目ではnil。
    /// - Parameters:
    ///   - title: 項目の名前の代わりに出す名前。投稿のメニューで、ユーザーの項目をサブメニューにせず並べるときに使う。
    ///   - host: コピーしたことを知らせる画面。
    @MainActor
    func action(_ item: UserMenuItem, target: UserMenuTarget, title: String? = nil, notifying host: (any LinkMenuHost)?) -> UIAction? {
        switch item {
        case .mention:
            return UIAction(title: title ?? item.title, image: item.image) { _ in mention(target) }
        case .copyHandle:
            return UIAction(title: title ?? item.title, image: item.image) { [weak host] _ in
                copyHandle(target) { host?.showHandleCopiedNotice() }
            }
        case .profile, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .follow, .showReblogs, .notify, .mute, .block, .report:
            return nil
        }
    }
}
