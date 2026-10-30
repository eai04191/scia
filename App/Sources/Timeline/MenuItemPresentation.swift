import SciaCore
import UIKit

@MainActor
extension MenuLayout.Groups {
    /// まとまりごとに区切り線で分けて並べ、「その他」の中身はサブメニューにする。中身のないまとまりと「その他」は出さない。
    /// 横並びのまとまりは、アイコンと名前を縦に積んだ中くらいの大きさで横に並べる。横に並ぶのは3個までで、4個目からはその下にふだんの行として続く。
    func menuElements(_ elements: (Item) -> [UIMenuElement]) -> [UIMenuElement] {
        arranged(elements, group: { children, isRow in
            let menu = UIMenu(options: .displayInline, children: children)
            if isRow { menu.preferredElementSize = .medium }
            return menu
        }, more: { UIMenu(title: "その他", image: UIImage(systemName: "ellipsis.circle"), children: $0) })
    }
}

extension MenuItemContentProviding {
    var image: UIImage? { UIImage(systemName: symbolName) }
}

/// ハッシュタグのメニュー。本文のハッシュタグの長押しと、投稿のメニューの「ハッシュタグ」で、同じ並びから組む。決まりはdocs/menus.mdの「メニューの単位」にある。
/// 項目の名前、並び、出す条件、見出し、動きはここだけが知る。出す場所は、タグと、その場所でしかできないこと（共有のシートを出す起点、一覧を開く先）だけを渡す。
@MainActor
struct HashtagMenu {
    /// `#`を除いた名前。
    let name: String
    /// サーバーのハッシュタグのページ。分からなければ、URLの項目を押せないまま並べる。
    let url: URL?
    /// 「投稿したユーザーの投稿」で開くユーザー。nilなら項目を出さない。
    let account: Account?
    /// URLの項目の動き。
    let handlers: URLMenuHandlers
    /// ミュートを読んで変えるもの。nilなら「ミュート」を出さない。
    let muteActions: HashtagMuteActions?
    /// 「すべての投稿」で、ハッシュタグのタイムラインを開く。
    let openTimeline: () -> Void
    /// 「投稿したユーザーの投稿」で、そのユーザーのハッシュタグの付いた投稿を開く。
    let openAccountStatuses: (Account) -> Void

    /// 本文のハッシュタグの長押しで単独で出すメニュー。見出しに`#名前`を置く。出す項目がなければnil。
    func menu(groups: MenuLayout<HashtagMenuItem>.Groups) -> UIMenu? {
        let children = elements(groups: groups)
        return children.isEmpty ? nil : UIMenu(title: "#\(name)", children: children)
    }

    /// 投稿のメニューの「ハッシュタグ」に並べる、`#名前`のサブメニュー。出す項目がなければnil。
    func submenu(groups: MenuLayout<HashtagMenuItem>.Groups) -> UIMenu? {
        let children = elements(groups: groups)
        return children.isEmpty ? nil : UIMenu(title: "#\(name)", image: StatusMenuItem.hashtags.image, children: children)
    }

    private func elements(groups: MenuLayout<HashtagMenuItem>.Groups) -> [UIMenuElement] {
        groups.menuElements { item in
            if let action = item.urlAction {
                return [action.action(url: url, handlers: handlers)]
            }
            switch item {
            case .timeline:
                return [UIAction(title: item.title, image: item.image) { [openTimeline] _ in openTimeline() }]
            case .accountStatuses:
                guard let account else { return [] }
                // ほかのサーバーのユーザーなら、ユーザーのメニューの見出しと同じく、サーバー名をサブタイトルに出す。
                return [UIAction(title: "@\(account.username)の投稿", subtitle: UserHeading(acct: account.acct).subtitle, image: item.image) { [openAccountStatuses] _ in openAccountStatuses(account) }]
            case .mute:
                guard let muteActions else { return [] }
                return muteElements(muteActions, item: item)
            // 共通の項目は、上で中身から組んだ。
            case .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
                return []
            }
        }
    }

    /// ミュートしていなければ、ユーザーのミュートと同じ期間をサブメニューで選び、ミュート中なら「ミュートを解除」にする。
    /// フィルターを覚えていれば、その場で決める。読み込み中の行を出してから中身を差し替えると、開く途中のサブメニューの動きが崩れるため。
    /// メニューを開くたびにフィルターを読み直し、別の端末やwebで変えたミュートを次に開いたときから反映する。
    /// まだ読めていなければ、読む間はUIKitの読み込み中の行を出し、読めなければ押せない行で知らせる。
    private func muteElements(_ muteActions: HashtagMuteActions, item: HashtagMenuItem) -> [UIMenuElement] {
        let name = name
        func elements(isMuted: Bool) -> [UIMenuElement] {
            if isMuted {
                return [UIAction(title: "ミュートを解除", image: UIImage(systemName: "speaker.wave.2")) { _ in muteActions.unmute(name) }]
            }
            return [UIMenu(title: item.title, image: item.image, children: UserRelationChange.muteDurations.map { choice in
                UIAction(title: choice.title) { _ in muteActions.mute(name, choice.duration) }
            })]
        }
        let isMuted = muteActions.known(name)
        muteActions.refresh()
        if let isMuted {
            return elements(isMuted: isMuted)
        }
        return [UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                do {
                    completion(elements(isMuted: try await muteActions.load(name)))
                } catch {
                    completion([UIAction(title: "ミュートを読み込めませんでした", image: UIImage(systemName: "exclamationmark.triangle"), attributes: .disabled) { _ in }])
                }
            }
        }]
    }
}

/// ハッシュタグのメニューの「ミュート」で、ミュートしているかを読み、変える。項目は`HashtagMenu`が組む。決まりはdocs/menus.mdの「ハッシュタグのメニュー」にある。
struct HashtagMuteActions {
    /// 覚えている自分のフィルターで決めた、`#`を除いた名前のタグをミュートしているか。フィルターをまだ読めていなければnil。
    let known: @MainActor (String) -> Bool?
    /// 自分のフィルターを読み直していなければ読み直す。メニューを開いたときに呼び、次に開いたときから使う。
    let refresh: @MainActor () -> Void
    /// `#`を除いた名前のタグをミュートしているか。フィルターを読み直している途中なら、それを待つ。
    let load: @MainActor (String) async throws -> Bool
    /// ミュートする。nilなら解除するまで続ける。
    let mute: @MainActor (String, Duration?) -> Void
    /// ミュートを解除する。解く条件は、解除するときにフィルターを読み直して決める。メニューを組んだときに覚えていた条件で消すと、
    /// その後に別の端末やwebで同じフィルターに足した条件まで、フィルターごと消してしまうため。
    let unmute: @MainActor (String) -> Void
}


extension UIMenu {
    /// ユーザーのメニュー。投稿のメニューのサブメニューでも、ほかの場所から出すメニューでも、見出しを`UserHeading`で揃える。
    /// - Parameter image: サブメニューの項目に付ける、その人のアイコン。単独で出すメニューではnil。
    static func user(acct: String, image: UIImage? = nil, children: [UIMenuElement]) -> UIMenu {
        let heading = UserHeading(acct: acct)
        // 単独で出すメニューの見出しでは、UIKitがサブタイトルを描かないため、サーバー名を2行目に置く。
        if image == nil, let subtitle = heading.subtitle {
            return UIMenu(title: "\(heading.title)\n\(subtitle)", children: children)
        }
        return UIMenu(title: heading.title, subtitle: heading.subtitle, image: image, children: children)
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

/// ユーザーのメニューの、投稿欄とログイン中のサーバーに頼る項目（メンション、ハンドルをコピー、関係の項目）の動き。項目は`UserMenu`が組む。
/// セッションが作り、画面を組み立てる側が渡す。渡されていない画面では、これらの項目を出さない。
struct UserMenuActions {
    /// 投稿欄で、カーソルの位置に`@acct`を入れる。
    let mention: @MainActor (UserMenuTarget) -> Void
    /// サーバー名を付けた`@username@domain`の形でコピーし、コピーできたら`notify`を呼ぶ。
    let copyHandle: @MainActor (UserMenuTarget, _ notify: @escaping @MainActor () -> Void) -> Void
    /// 相手のIDと`acct`を決める。リンクのメンションは、プロフィールのURLから探す。見つからなければ投げる。
    let resolveTarget: @MainActor (UserMenuTarget) async throws -> UserIdentity
    /// `resolveTarget`で決めた相手と自分の関係を読む。覚えている関係を読み直している途中なら、それを待つ。自分ならnil。
    let loadRelation: @MainActor (UserMenuTarget, UserIdentity) async throws -> UserRelation?
    /// 手元で分かっている相手との関係。相手のIDが分からないか、関係を覚えていなければnil。
    let knownRelation: @MainActor (UserMenuTarget) -> KnownRelation?
    /// 相手たちとの関係をまとめて1回で読み直し、覚えておく。自分は除く。
    let reloadRelations: @MainActor ([String]) -> Void
    /// 関係の項目で選んだ変更を送る。取り消しにくい変更は、確かめてから送る。
    let changeRelation: @MainActor (UserRelationChange, UserRelation) -> Void
    /// 相手のプロフィールに書く、自分にしか見えないメモのシートを開く。
    let editNote: @MainActor (UserRelation) -> Void
    /// 通報のシートを開く。投稿のメニューから開いたときは、添えられる相手の投稿のIDを渡す。
    let report: @MainActor (_ accountID: String, _ acct: String, _ statusID: String?) -> Void
    /// セッションで読んだアカウント。メンションされたユーザーのように、アイコンのURLが手元にない相手のアイコンを出すのに使う。
    let accounts: AccountCache

}
