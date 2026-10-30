public import Foundation

/// 投稿に対する操作。一覧では長押しのメニューから選ぶ。
public enum StatusAction: Sendable {
    case reply
    case favourite
    case reblog
    /// 公開範囲を選んでブーストする。
    case reblogWithVisibility(ReblogVisibility)
    case bookmark
    /// 投稿欄で投稿を引用して書き始める。
    case quote
    case muteConversation
    case pin
    case editHistory
    /// 投稿をお気に入りした人の一覧を開く。
    case openFavouritedBy
    /// 投稿をブーストした人の一覧を開く。
    case openRebloggedBy
    case edit
    case delete
}

/// フォローリクエストへの返事。
public enum FollowRequestDecision: Sendable {
    case authorize
    case reject
}

/// 投稿のメニューの項目を押したときの操作。対象の投稿や通知は、メニューを出した場所が知っている。
public enum StatusMenuCommand {
    /// 投稿への操作。サーバーに送るものと、画面を開くもの。
    case status(StatusAction)
    case openThread
    case dismissNotification
    /// 添付ファイルをぼかす。
    case hideMedia
    case copyText(String)
    case translate(String)
    /// 本文の文字を選び始める。
    case selectText
    case url(URLMenuCommand)
    /// フォローリクエストの通知の、承認と却下。
    case followRequest(FollowRequestDecision)
    /// ユーザーのメニューのサブメニューの項目。
    case user(MenuUser, UserMenuCommand)
    /// ハッシュタグのメニューのサブメニューの項目。
    case hashtag(Tag, HashtagMenuCommand)
    /// カスタム絵文字の画像の、メディアのメニューのサブメニューの項目。
    indirect case customEmoji(CustomEmoji, MediaMenuCommand)
}

/// 投稿の長押しのメニュー。並びは設定の投稿のメニューに従い、関係するユーザーはユーザーのメニューのサブメニューにする。決まりはdocs/menus.mdにある。
/// 項目ごとの出す条件、名前とアイコンの切り替え、押せない理由はここだけが知る。画面の状態に頼る条件（スレッドを開けるか、ぼかしているか、本文を選べるか）は、メニューを出す場所が渡す。
@MainActor
public struct StatusMenuTree {
    /// メニューを出した要素の投稿。通知なら対象の投稿。投稿のない通知ではnil。
    public let status: Status?
    /// 通知のメニューなら、その通知。
    public let notification: MastodonNotification?
    /// メニューを出した行の投稿。通報に添える投稿を、この投稿から決める。引用の囲みのメニューでは、囲みの投稿ではなく行の投稿になる。
    public var rowStatus: Status?
    /// 自分のアカウントのID。分からない一覧ではnilで、自分の投稿でだけ出る項目と、ブーストに関わる項目を出さない。
    public var myAccountID: String?
    /// 今の時刻。締め切りの近い投票を編集できないかを決める。
    public var now: Date
    /// 開く場所の設定。メニューを組むときの値で決める。
    public var linkBrowser: LinkBrowser
    /// 行のスレッドを開けるか。スレッドの中心の投稿では開けない。
    public var canOpenThread = false
    /// 添付ファイルをぼかしているか。ぼかしている投稿では「メディアを隠す」を出さない。
    public var mediaIsCovered = false
    /// 本文の文字を選べるか。本文を表示している行でだけ選べる。
    public var canSelectText = false
    /// ユーザーのメニューの並びと、メンション、ハンドルをコピー、関係の項目を組むもの。
    public var userMenu: MenuLayout<UserMenuItem>.Groups = UserMenuItem.defaultLayout.groups
    public var userActions: UserMenuActions?
    /// ハッシュタグのメニューの並びと、ミュートを読むもの。
    public var hashtagMenu: MenuLayout<HashtagMenuItem>.Groups = HashtagMenuItem.defaultLayout.groups
    public var hashtagMute: HashtagMuteActions?
    /// カスタム絵文字の画像のメディアのメニュー。メディアを共有や保存できるかは置く側で決まるため、置く側が組む。
    public var customEmoji: @MainActor (CustomEmoji) -> MenuNode<MediaMenuCommand>? = { _ in nil }

    public init(status: Status?, notification: MastodonNotification?, now: Date, linkBrowser: LinkBrowser) {
        self.status = status
        self.notification = notification
        rowStatus = status
        self.now = now
        self.linkBrowser = linkBrowser
    }

    /// 組んだメニュー。出す項目がなければ`root`はnil。
    public struct Built {
        public let root: MenuNode<StatusMenuCommand>?
        /// ユーザーのメニューを出した人のID。メニューを開いたときに、関係をまとめて1回で読み直す。
        public let shownUserIDs: [String]
    }

    /// 投稿のメニュー。フォローリクエストの通知では、設定の並びの前に、承認と却下を設定によらず置く。
    /// - Parameter groups: 組む並び。タップや長押しに割り当てた1項目だけを組むときは、その項目だけの並びを渡し、承認と却下は置かない。
    /// - Parameter includesFollowRequest: 承認と却下を置くか。設定の並びで組むときだけtrueにする。
    public func menu(groups: MenuLayout<StatusMenuItem>.Groups, includesFollowRequest: Bool) -> Built {
        var shownUserIDs: [String] = []
        var seenUserIDs: Set<String> = []
        var children = groups.nodes { item in
            nodes(for: item) { users in
                // 同じユーザーが2つの項目に当たるときは、先に出る項目で1度だけ出す。
                users.filter { seenUserIDs.insert($0.id).inserted }.compactMap { user in
                    shownUserIDs.append(user.id)
                    return userNode(for: user)
                }
            }
        }
        if includesFollowRequest, let notification, notification.type == .followRequest {
            children.insert(.group([
                .action("承認", icon: .symbol("checkmark"), .followRequest(.authorize)),
                .action("却下", icon: .symbol("xmark"), isDestructive: true, .followRequest(.reject)),
            ]), at: 0)
        }
        return Built(root: children.isEmpty ? nil : .submenu("", children), shownUserIDs: shownUserIDs)
    }

    /// - Parameter users: ユーザーのメニューのサブメニューを組む。まだ出していない人だけを組む。
    private func nodes(for item: StatusMenuItem, users: ([MenuUser]) -> [MenuNode<StatusMenuCommand>]) -> [MenuNode<StatusMenuCommand>] {
        switch item {
        case .notifyingUser:
            // まとめた通知では、並べた人をみな出す。
            return users(notification.map { $0.sampleAccounts.map(MenuUser.account) } ?? [])
        case .reblogWithVisibility:
            guard let status else { return [] }
            return reblogWithVisibilityMenu(for: status, item: item).map { [$0] } ?? []
        case .dismissNotification:
            // 投稿のない通知（フォローなど）でも出す。
            guard notification != nil else { return [] }
            return [.action(item.title, icon: .symbol(item.symbolName), .dismissNotification)]
        case .openThread:
            guard status != nil, canOpenThread else { return [] }
            return [.action(item.title, icon: .symbol(item.symbolName), .openThread)]
        case .author:
            return users(status.map { [.account($0.displayed.account)] } ?? [])
        case .booster:
            guard let status, status.reblog != nil else { return [] }
            return users([.account(status.account)])
        case .mentionedUsers:
            return users(status?.displayed.mentions.map(MenuUser.mention) ?? [])
        case .customEmojis:
            let emojis = notification?.emojisInRow ?? status?.emojisInRow ?? []
            return emojis.compactMap { emoji in customEmoji(emoji)?.map { .customEmoji(emoji, $0) } }
        case .hashtags:
            guard let shown = status?.displayed else { return [] }
            return hashtagNodes(of: shown)
        case .reply, .favourite, .reblog, .bookmark, .quote, .muteConversation, .pin, .copyLink, .copyText, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .editHistory, .favouritedBy, .rebloggedBy, .hideMedia, .systemTranslate, .selectText, .edit, .delete:
            guard let status else { return [] }
            return statusNode(item, on: status).map { [$0] } ?? []
        }
    }

    /// 投稿への操作。ユーザーの項目は`userNode(for:)`で組むため、nilを返す。
    private func statusNode(_ item: StatusMenuItem, on status: Status) -> MenuNode<StatusMenuCommand>? {
        let shown = status.displayed
        let icon = MenuIcon.symbol(item.symbolName)
        if let action = item.urlAction {
            // `url`はMastodonのAPIでnullを取りうるため、ないときは押せないまま並べる。`uri`はActivityPubのIDで、ブラウザで開けるページとは限らないため代わりにしない。
            // ブーストなら元の投稿のページを指す。
            return action.node(url: shown.url, linkBrowser: linkBrowser).map(StatusMenuCommand.url)
        }
        switch item {
        case .reply:
            return .action(item.title, icon: icon, .status(.reply))
        case .favourite:
            return .action(shown.favourited ? "お気に入りを取り消す" : item.title, icon: shown.favourited ? .symbol("star.slash") : icon, .status(.favourite))
        case .reblog:
            return .action(shown.reblogged ? "ブーストを取り消す" : item.title, icon: icon, isEnabled: canReblog(status), .status(.reblog))
        case .bookmark:
            return .action(shown.bookmarked ? "ブックマークを外す" : item.title, icon: shown.bookmarked ? .symbol("bookmark.slash") : icon, .status(.bookmark))
        case .quote:
            return quoteNode(item, on: status)
        case .muteConversation:
            // サーバーはどの会話でもミュートできるが、通知が届かない会話をミュートしても変わらないため、自分が加わっていそうな投稿でだけ出す。
            // 自分が途中で返信した会話で、自分へのメンションを含まない投稿には出ない。そのときは、通知か自分の投稿からミュートする。
            guard let myAccountID,
                  notification != nil || shown.account.id == myAccountID || shown.mentions.contains(where: { $0.id == myAccountID })
            else { return nil }
            return .action(shown.muted ? "会話のミュートを解除" : item.title, icon: shown.muted ? .symbol("bell") : icon, .status(.muteConversation))
        case .pin:
            guard let myAccountID, status.canBePinned(by: myAccountID) else { return nil }
            return .action(shown.pinned ? "プロフィールの固定を外す" : item.title, icon: shown.pinned ? .symbol("pin.slash") : icon, .status(.pin))
        case .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            // 共通の項目は、上で中身から組んだ。
            return nil
        case .editHistory:
            guard shown.editedAt != nil else { return nil }
            return .action(item.title, icon: icon, .status(.editHistory))
        case .favouritedBy:
            // サーバーの数は、このサーバーが知っている分で、一覧もこのサーバーが知っている人だけを返すため、数が0なら出さない。
            guard shown.favouritesCount > 0 else { return nil }
            return .action(item.title, subtitle: "\(shown.favouritesCount.formatted())人", icon: icon, .status(.openFavouritedBy))
        case .rebloggedBy:
            guard shown.reblogsCount > 0 else { return nil }
            return .action(item.title, subtitle: "\(shown.reblogsCount.formatted())人", icon: icon, .status(.openRebloggedBy))
        case .edit:
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            // 投票の締め切りが近い投稿は、送り直すとサーバーが拒むので、押せないまま理由を添える。
            let canEdit = status.canBeEdited(now: now)
            return .action(item.title, subtitle: canEdit ? nil : "締め切りまで5分を切った投票は編集できません", icon: icon, isEnabled: canEdit, .status(.edit))
        case .delete:
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            return .action(item.title, icon: icon, isDestructive: true, .status(.delete))
        case .hideMedia:
            // ぼかしている投稿では出さない。開くときは、閲覧注意と同じくぼかしをタップする。
            guard !shown.mediaAttachments.isEmpty, !mediaIsCovered else { return nil }
            let isImageOnly = shown.mediaAttachments.allSatisfy { $0.type == .image }
            return .action(isImageOnly ? "画像を隠す" : item.title, icon: icon, .hideMedia)
        case .copyText:
            guard let text = Self.plainText(of: shown) else { return nil }
            return .action(item.title, icon: icon, .copyText(text))
        case .systemTranslate:
            guard let text = Self.plainText(of: shown) else { return nil }
            return .action(item.title, icon: icon, .translate(text))
        case .selectText:
            guard canSelectText else { return nil }
            return .action(item.title, icon: icon, .selectText)
        case .openThread, .notifyingUser, .author, .booster, .mentionedUsers, .customEmojis, .hashtags, .dismissNotification, .reblogWithVisibility:
            return nil
        }
    }

    /// 投稿のメニューに置く、ユーザーのメニューのサブメニュー。
    /// Mastodonは通報する相手の投稿しか添えられないため、長押しした投稿をその人が書いたときだけ添える。
    private func userNode(for user: MenuUser) -> MenuNode<StatusMenuCommand>? {
        let shown = rowStatus?.displayed
        let tree = UserMenuTree(subject: UserMenuSubject(user), actions: userActions, linkBrowser: linkBrowser, reportableStatusID: shown?.account.id == user.id ? shown?.id : nil)
        return tree.submenu(groups: userMenu, avatar: .user(user))?.map { .user(user, $0) }
    }

    /// 投稿のハッシュタグごとの、ハッシュタグのメニューのサブメニュー。中身は本文のハッシュタグを長押ししたときと同じ。
    /// サーバーと同じ決まりでそろえた名前が同じタグは、1度だけ出す。
    private func hashtagNodes(of shown: Status) -> [MenuNode<StatusMenuCommand>] {
        var seen: Set<String> = []
        return shown.tags.filter { seen.insert(Hashtag.normalizedName($0.name)).inserted }.compactMap { tag in
            HashtagMenuTree(name: tag.name, url: tag.url, account: shown.account, linkBrowser: linkBrowser, muteActions: hashtagMute)
                .submenu(groups: hashtagMenu)?
                .map { .hashtag(tag, $0) }
        }
    }

    /// 引用の項目。引用に対応していないサーバー（`quote_approval`がない）では出さない。押せるかを決められないため。
    /// 投稿者の承認が要るときと、引用できないときは、そのことをサブタイトルに添える。決まりはdocs/quote.mdの「引用して投稿する」にある。
    private func quoteNode(_ item: StatusMenuItem, on status: Status) -> MenuNode<StatusMenuCommand>? {
        guard let availability = status.displayed.quoteApproval?.availability else { return nil }
        let subtitle: String? = switch availability {
        // ログインしていない人向けに届いた投稿は、押してから確かめる。
        case .automatic, .unverified: nil
        case .manual: "投稿者が承認すると表示されます"
        case .denied(followersOnly: true): "フォロワーだけが引用できます"
        case .denied(followersOnly: false): "引用できない投稿です"
        }
        return .action(item.title, subtitle: subtitle, icon: .symbol(item.symbolName), isEnabled: availability.canQuote, .status(.quote))
    }

    /// 公開範囲を選んでブーストするサブメニュー。ブーストを取り消すのは「ブースト」の項目に任せ、ブーストしていない投稿でだけ出す。
    /// フォロワーのみの投稿は、選んでも元の投稿と同じ公開範囲でブーストされるため出さない。
    private func reblogWithVisibilityMenu(for status: Status, item: StatusMenuItem) -> MenuNode<StatusMenuCommand>? {
        let shown = status.displayed
        guard canReblog(status), !shown.reblogged, shown.visibility == .public || shown.visibility == .unlisted else { return nil }
        let choices: [(ReblogVisibility, Status.Visibility)] = [(.public, .public), (.unlisted, .unlisted), (.private, .private)]
        return .submenu(item.title, icon: .symbol(item.symbolName), choices.map { reblogVisibility, visibility in
            let option = VisibilityOption(visibility)
            return .action(option.title, icon: .symbol(option.symbolName), .status(.reblogWithVisibility(reblogVisibility)))
        })
    }

    private func canReblog(_ status: Status) -> Bool {
        guard let myAccountID else { return false }
        return status.canBeReblogged(by: myAccountID)
    }

    /// コピーや翻訳に渡す本文。書式やリンクは落とし、文字だけにする。カスタム絵文字は`:shortcode:`のまま残す。
    /// 本文が空白だけならnil。
    public static func plainText(of status: Status) -> String? {
        let text = RichText.status(status).plainText
        return text.allSatisfy(\.isWhitespace) ? nil : text
    }
}
