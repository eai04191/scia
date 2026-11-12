public import Foundation

/// 投稿に対する操作。タイムラインではメニューから選ぶ。
public enum StatusAction: Sendable {
    case reply
    case favourite
    case reblog
    /// 公開範囲を選んでブーストする。
    case reblogWithVisibility(ReblogVisibility)
    case bookmark
    /// 投稿欄で投稿を引用して書き始める。
    case quote
    /// 絵文字のシートを開き、選んだ絵文字で投稿にリアクションする。
    case react
    case muteConversation
    case pin
    case editHistory
    /// 投稿をお気に入りした人のリストを開く。
    case openFavouritedBy
    /// 投稿をブーストした人のリストを開く。
    case openRebloggedBy
    /// 投稿を引用した投稿のタイムラインを開く。
    case openQuotes
    /// 自分の投稿を引用できる人を変える。
    case setQuotePolicy(QuotePolicy)
    /// 自分の投稿への、この投稿による引用を取り消す。
    case revokeQuote
    case edit
    case delete
    /// 投稿欄に戻して書き直し、送るときに元の投稿を削除する。
    case redraft
    /// 投稿をサーバーから読み直し、APIの応答のJSONを出す。
    case viewAPIResponse
}

/// 自動翻訳の訳文を持っている投稿で、今出している本文。
public enum TranslationDisplay: Sendable {
    case translation
    case original
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
    /// 自動翻訳の原文と訳文を切り替える。
    case toggleTranslation
    /// 本文の文字を選び始める。
    case selectText
    /// タイムラインで、この投稿を1番目にして投稿を選び始める。
    case select
    case url(URLMenuCommand)
    /// フォローリクエストの通知の、承認と却下。
    case followRequest(FollowRequestDecision)
    /// 保留中の通知の行の、受け入れると無視。
    case notificationRequest(NotificationRequestDecision)
    /// ユーザーのメニューのサブメニューの項目。
    case user(MenuUser, UserMenuCommand)
    /// ハッシュタグのメニューのサブメニューの項目。
    case hashtag(Tag, HashtagMenuCommand)
    /// カスタム絵文字の画像の、メディアのメニューのサブメニューの項目。
    indirect case customEmoji(CustomEmoji, MediaMenuCommand)
    /// 「別のアカウントで」の、ほかのアカウントとしての操作。
    case otherAccount(OtherAccountCommand)
    /// ログアウトされたアカウントにログインし直す。「別のアカウントで」で、そのアカウントで投稿を探せなかったときに出す。
    case logIn(RequestAccount)
    /// このメニューの並びの設定の画面を開く。
    case customize
}

/// 「別のアカウントで」で選んだ、ほかのアカウントとしての操作。
public struct OtherAccountCommand {
    public let account: OtherAccount
    /// メニューを出した、今のアカウントでの投稿。失敗を記録するときに、今のアカウントのタイムラインの投稿を指すのに使う。
    public let original: Status
    public let action: Action

    public enum Action {
        /// そのアカウントから見た投稿への操作。投稿のIDはそのアカウントのサーバーのもの。
        case status(Status, StatusAction)
        /// 投稿に出る人への操作。
        case user(OtherAccountUserAction)
        /// 投稿のハッシュタグを、そのアカウントでフォロー、ミュート、プロフィールで紹介する。
        case hashtag(Tag, HashtagMenuCommand)
    }
}

/// 投稿のメニュー。並びは設定の投稿のメニューに従い、関係するユーザーはユーザーのメニューのサブメニューにする。決まりはdocs/menus.mdにある。
/// 項目ごとの出す条件、名前とアイコンの切り替え、押せない理由はここだけが知る。画面の状態に頼る条件（スレッドを開けるか、ぼかしているか、本文を選べるか）は、メニューを出す場所が渡す。
@MainActor
public struct StatusMenuTree {
    /// メニューを出した要素の投稿。通知なら対象の投稿。投稿のない通知ではnil。
    public let status: Status?
    /// 通知のメニューなら、その通知。
    public let notification: MastodonNotification?
    /// メニューを出した行の投稿。通報に添える投稿を、この投稿から決める。引用の囲みのメニューでは、囲みの投稿ではなく行の投稿になる。
    public var rowStatus: Status?
    /// 自分のアカウントのID。分からないタイムラインではnilで、自分の投稿でだけ出る項目と、ブーストに関わる項目を出さない。
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
    /// 自動翻訳の訳文を持っている投稿で、今どちらを出しているか。持っていなければnil。
    public var translationDisplay: TranslationDisplay?
    /// タイムラインで投稿を選び始められるか。投稿を選べるタイムラインの行でだけ選べる。
    public var canSelectPosts = false
    /// サーバーが投稿への絵文字のリアクションに対応しているか。対応していなければ「リアクション」を出さない。
    public var supportsEmojiReactions = false
    /// ユーザーのメニューの並びと、メンション、ハンドルをコピー、関係の項目を組むもの。
    public var userMenu: MenuLayout<UserMenuItem>.Groups = UserMenuItem.defaultLayout.groups
    public var userActions: UserMenuActions?
    /// ハッシュタグのメニューの並びと、ミュートを読むもの。
    public var hashtagMenu: MenuLayout<HashtagMenuItem>.Groups = HashtagMenuItem.defaultLayout.groups
    public var hashtagActions: HashtagMenuActions?
    /// カスタム絵文字の画像のメディアのメニュー。メディアを共有や保存できるかは置く側で決まるため、置く側が組む。
    public var customEmoji: @MainActor (CustomEmoji) -> MenuNode<MediaMenuCommand>? = { _ in nil }
    /// 「別のアカウントで」に並べる、ログインしているほかのアカウント。空なら項目を出さない。
    public var otherAccounts: [OtherAccount] = []
    /// 「別のアカウントで」の中の並び。投稿のメニューの、ほかのメニューの中に出すときの並び（`submenuGroups`）を渡す。
    public var otherAccountGroups: MenuLayout<StatusMenuItem>.Groups = StatusMenuItem.defaultLayout.groups
    /// ユーザーのメニューのサブメニューに付ける、その人のアイコン。nilならアイコンを付けない。
    /// 「別のアカウントで」の中身では、人のIDがそのアカウントのサーバーのものなので、今のアカウントで同じ人を探して付ける。
    var userAvatar: (MenuUser) -> MenuAvatar? = { .user($0) }
    /// 「ブーストした人」に出す人。ブーストでなければnil。
    /// 「別のアカウントで」の中身では、見つけた投稿がブーストの元の投稿なので、そのサーバーで探した人を入れる。
    var booster: Account?
    /// 「通知した人」に出す人。まとめた通知では並べた人をみな出す。
    /// 「別のアカウントで」の中身では、そのサーバーで探した人を入れる。
    var notifyingAccounts: [Account]

    public init(status: Status?, notification: MastodonNotification?, now: Date, linkBrowser: LinkBrowser) {
        self.status = status
        self.notification = notification
        rowStatus = status
        self.now = now
        self.linkBrowser = linkBrowser
        booster = status?.reblog != nil ? status?.account : nil
        notifyingAccounts = notification?.sampleAccounts ?? []
    }

    /// 組んだメニュー。出す項目がなければ`root`はnil。
    public struct Built {
        public let root: MenuNode<StatusMenuCommand>?
        /// ユーザーのメニューを出した人のID。メニューを開いたときに、関係をまとめて1回で読み直す。
        public let shownUserIDs: [String]
        /// 「別のアカウントで」を組んだか。組んだときだけ、前に見つけた投稿を探し直す。
        public let showsOtherAccounts: Bool
        /// 「別のアカウントで」の中で、そのアカウントから見た投稿に、関係の項目を出す人のID。探し直したあとに、関係をまとめて読み直す。
        public let otherAccountRelationIDs: @MainActor (_ found: Status, OtherAccount) -> [String]
        /// 「別のアカウントで」の中で、見つけた投稿のほかに出す人（ブーストした人、通知した人）。探し直すときに、まだ見つけていない人をそのサーバーで探す。
        public let otherAccountPeople: [Account]
        /// ユーザーのメニューの「別のアカウントで」の、ほかのアカウントのアイコンと、前に見つけた人との関係を読み直す。メニューを開くときに呼ぶ。
        public let refreshOtherAccountUsers: @MainActor () -> Void
    }

    /// 投稿のメニュー。フォローリクエストの通知では、設定の並びの前に、承認と却下を設定によらず置く。
    /// - Parameter groups: 組む並び。タップや長押しに割り当てた1項目だけを組むときは、その項目だけの並びを渡し、承認と却下は置かない。
    /// - Parameter includesFollowRequest: 承認と却下を置くか。設定の並びで組むときだけtrueにする。
    public func menu(groups: MenuLayout<StatusMenuItem>.Groups, includesFollowRequest: Bool) -> Built {
        var shownUserIDs: [String] = []
        var shownUsers: [MenuUser] = []
        var seenUserIDs: Set<String> = []
        var showsOtherAccounts = false
        var children = groups.nodes { item in
            let built = nodes(for: item) { users in
                // 同じユーザーが2つの項目に当たるときは、先に出る項目で1度だけ出す。
                users.filter { seenUserIDs.insert($0.id).inserted }.compactMap { user in
                    shownUserIDs.append(user.id)
                    shownUsers.append(user)
                    return userNode(for: user)
                }
            }
            if item == .otherAccounts, !built.isEmpty { showsOtherAccounts = true }
            return built
        }
        if includesFollowRequest, let notification, notification.type == .followRequest {
            children.insert(.group([
                .action("承認", icon: .symbol("checkmark"), .followRequest(.authorize)),
                .action("却下", icon: .symbol("xmark"), isDestructive: true, .followRequest(.reject)),
            ]), at: 0)
        }
        return Built(
            root: children.isEmpty ? nil : .submenu("", children),
            shownUserIDs: shownUserIDs,
            showsOtherAccounts: showsOtherAccounts,
            otherAccountRelationIDs: { [self] found, account in otherAccountRelationIDs(in: found, as: account) },
            otherAccountPeople: otherAccountPeople,
            refreshOtherAccountUsers: { [self, shownUsers] in
                // 人ごとに送らず、ほかのアカウントごとにまとめて1回で読む。
                UserMenuTree.refreshOtherAccounts(of: shownUsers.map(userTree(for:)), groups: userMenu)
            }
        )
    }

    /// 保留中の通知の行のメニュー。「受け入れる」と「無視」を1つのまとまりで置き、その下にその人のユーザーのメニューを並べる。
    /// 2つは並びの設定に載せない固定の項目。決まりはdocs/notification-filter.mdにある。
    /// - Parameter user: その人のユーザーのメニュー。出す項目がなければnil。
    public static func notificationRequestMenu(user: MenuNode<StatusMenuCommand>?) -> MenuNode<StatusMenuCommand> {
        let answers = MenuNode<StatusMenuCommand>.group([
            .action("受け入れる", icon: .symbol("checkmark"), .notificationRequest(.accept)),
            .action("無視", icon: .symbol("xmark"), isDestructive: true, .notificationRequest(.dismiss)),
        ])
        return .submenu("", [answers] + (user.map { [$0] } ?? []))
    }

    /// - Parameter users: ユーザーのメニューのサブメニューを組む。まだ出していない人だけを組む。
    private func nodes(for item: StatusMenuItem, users: ([MenuUser]) -> [MenuNode<StatusMenuCommand>]) -> [MenuNode<StatusMenuCommand>] {
        switch item {
        case .notifyingUser:
            return users(notifyingAccounts.map(MenuUser.account))
        case .reblogWithVisibility:
            guard let status else { return [] }
            return reblogWithVisibilityMenu(for: status, item: item).map { [$0] } ?? []
        case .quotePolicy:
            guard let status else { return [] }
            return quotePolicyMenu(for: status, item: item).map { [$0] } ?? []
        case .otherAccounts:
            guard let status else { return [] }
            return otherAccountsMenu(for: status, item: item).map { [$0] } ?? []
        case .dismissNotification:
            // 投稿のない通知（フォローなど）でも出す。
            guard notification != nil else { return [] }
            return [.action(item.title, icon: .symbol(item.symbolName), .dismissNotification)]
        case .openThread:
            guard status != nil, canOpenThread else { return [] }
            return [.action(item.title, icon: .symbol(item.symbolName), .openThread)]
        case .select:
            guard status != nil, canSelectPosts else { return [] }
            return [.action(item.title, icon: .symbol(item.symbolName), .select)]
        case .author:
            return users(status.map { [.account($0.displayed.account)] } ?? [])
        case .booster:
            return users(booster.map { [.account($0)] } ?? [])
        case .mentionedUsers:
            return users(status?.displayed.mentions.map(MenuUser.mention) ?? [])
        case .customEmojis:
            // 投稿の行に出しているリアクションのカスタム絵文字も含める。行に見えている絵文字をどれでも調べられるようにするため（docs/emoji-reaction.md）。
            let reactionEmojis = notification == nil && supportsEmojiReactions ? status?.displayed.emojiReactions.compactMap(\.emoji.customEmoji) ?? [] : []
            var seen: Set<URL> = []
            let emojis = ((notification?.emojisInRow ?? status?.emojisInRow ?? []) + reactionEmojis).filter { seen.insert($0.url).inserted }
            return emojis.compactMap { emoji in customEmoji(emoji)?.map { .customEmoji(emoji, $0) } }
        case .hashtags:
            guard let shown = status?.displayed else { return [] }
            return hashtagNodes(of: shown)
        case .customize:
            // 投稿のない通知（フォローなど）でも出す。
            return [.action(item.title, icon: .symbol(item.symbolName), .customize)]
        case .reply, .favourite, .reblog, .bookmark, .quote, .emojiReaction, .muteConversation, .pin, .toggleTranslation, .copyLink, .copyText, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .editHistory, .favouritedBy, .rebloggedBy, .quotedBy, .revokeQuote, .hideMedia, .systemTranslate, .selectText, .edit, .delete, .redraft, .apiResponse:
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
        case .emojiReaction:
            guard supportsEmojiReactions else { return nil }
            return .action(item.title, icon: icon, .status(.react))
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
            // サーバーの数は、このサーバーが知っている分で、人のリストもこのサーバーが知っている人だけを返すため、数が0なら出さない。
            guard shown.favouritesCount > 0 else { return nil }
            return .action(item.title, subtitle: "\(shown.favouritesCount.formatted())人", icon: icon, .status(.openFavouritedBy))
        case .rebloggedBy:
            guard shown.reblogsCount > 0 else { return nil }
            return .action(item.title, subtitle: "\(shown.reblogsCount.formatted())人", icon: icon, .status(.openRebloggedBy))
        case .quotedBy:
            guard shown.quotesCount > 0 else { return nil }
            return .action(item.title, subtitle: "\(shown.quotesCount.formatted())件", icon: icon, .status(.openQuotes))
        case .revokeQuote:
            // どこに出ている投稿でも、自分の投稿を引用していて、引用が認められていれば出す。取り消すと戻せないので、赤で出す。
            guard let myAccountID, shown.quote?.state == .accepted, shown.quote?.quotedStatus?.account.id == myAccountID else { return nil }
            return .action(item.title, icon: icon, isDestructive: true, .status(.revokeQuote))
        case .edit:
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            // 投票の締め切りが近い投稿は、送り直すとサーバーが拒むので、押せないまま理由を添える。
            let obstacle = status.editObstacle(now: now)
            return .action(item.title, subtitle: obstacle?.menuReason, icon: icon, isEnabled: obstacle == nil, .status(.edit))
        case .delete:
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            return .action(item.title, icon: icon, isDestructive: true, .status(.delete))
        case .redraft:
            // 送ると元の投稿が消えるので、削除と同じく赤で出す。
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            return .action(item.title, icon: icon, isDestructive: true, .status(.redraft))
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
        case .toggleTranslation:
            guard let translationDisplay else { return nil }
            return .action(translationDisplay == .original ? "訳文を表示" : item.title, icon: icon, .toggleTranslation)
        case .selectText:
            guard canSelectText else { return nil }
            return .action(item.title, icon: icon, .selectText)
        case .apiResponse:
            return .action(item.title, icon: icon, .status(.viewAPIResponse))
        case .openThread, .select, .notifyingUser, .author, .booster, .mentionedUsers, .customEmojis, .hashtags, .dismissNotification, .reblogWithVisibility, .quotePolicy, .otherAccounts, .customize:
            return nil
        }
    }

    /// 投稿のメニューに置く、ユーザーのメニューのサブメニュー。
    /// Mastodonは通報する相手の投稿しか添えられないため、長押しした投稿をその人が書いたときだけ添える。
    private func userNode(for user: MenuUser) -> MenuNode<StatusMenuCommand>? {
        userTree(for: user).submenu(groups: userMenu, avatar: userAvatar(user))?.map { .user(user, $0) }
    }

    private func userTree(for user: MenuUser) -> UserMenuTree {
        let shown = rowStatus?.displayed
        return UserMenuTree(subject: UserMenuSubject(user), actions: userActions, linkBrowser: linkBrowser, reportableStatusID: shown?.account.id == user.id ? shown?.id : nil)
    }

    /// 投稿のハッシュタグごとの、ハッシュタグのメニューのサブメニュー。中身は本文のハッシュタグを長押ししたときと同じ。
    /// サーバーと同じ決まりでそろえた名前が同じタグは、1度だけ出す。
    private func hashtagNodes(of shown: Status) -> [MenuNode<StatusMenuCommand>] {
        var seen: Set<String> = []
        return shown.tags.filter { seen.insert(Hashtag.normalizedName($0.name)).inserted }.compactMap { tag in
            HashtagMenuTree(name: tag.name, url: tag.url, account: shown.account, linkBrowser: linkBrowser, actions: hashtagActions)
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

    /// 自分の投稿を引用できる人を変えるサブメニュー。今の値にチェックマークを付け、項目のサブタイトルにも出す。
    /// 引用に対応していないサーバーの投稿（`quote_approval`がない）と、ほかの人の投稿では出さない。
    /// フォロワーのみとメンションした相手のみの投稿は、サーバーがいつも「自分のみ」にするので、押せない形で理由を添える。
    private func quotePolicyMenu(for status: Status, item: StatusMenuItem) -> MenuNode<StatusMenuCommand>? {
        guard let myAccountID, status.isAuthored(by: myAccountID), let approval = status.displayed.quoteApproval else { return nil }
        let icon = MenuIcon.symbol(item.symbolName)
        if let reason = QuotePolicy.fixedReason(for: status.displayed.visibility) {
            return .action(item.title, subtitle: reason, icon: icon, isEnabled: false, nil)
        }
        let current = approval.policy
        return .submenu(item.title, subtitle: current.title, icon: icon, QuotePolicy.allCases.map { policy in
            .action(policy.title, icon: .symbol(policy.symbolName), isSelected: policy == current, .status(.setQuotePolicy(policy)))
        })
    }

    /// 「別のアカウントで」の中に出さない項目。どのアカウントで行っても同じ結果になるもの（コピー、共有、今のアカウントで画面を開くもの、このタイムラインの表示を変えるもの）。
    static let sameForEveryAccountItems: Set<StatusMenuItem> = [
        .openThread, .select, .copyLink, .copyText, .selectText, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari,
        .editHistory, .favouritedBy, .rebloggedBy, .quotedBy, .dismissNotification, .hideMedia, .systemTranslate, .toggleTranslation, .customEmojis, .apiResponse, .otherAccounts, .customize,
        // 引用できる人と引用の取り消しは、アカウントによって結果が違うが、「別のアカウントで」からは行えない。
        // ほかのアカウントの自分の投稿への操作で、編集や削除と違い、ほかのアカウントから行う経路をまだ作っていないため。
        .quotePolicy, .revokeQuote,
    ]
    /// 「別のアカウントで」のハッシュタグのメニューに出さない項目。どのアカウントで行っても同じ結果になるもの。
    static let sameForEveryAccountHashtagItems: Set<HashtagMenuItem> = [.timeline, .accountStatuses, .addToCompose, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .copyLink, .share, .customize]
    /// 「別のアカウントで」のユーザーのメニューに出さない項目。どのアカウントで行っても同じ結果になるもの。
    static let sameForEveryAccountUserItems: Set<UserMenuItem> = [.profile, .copyHandle, .copyUsername, .copyServer, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .autoTranslation, .customize]

    /// 「別のアカウントで」のサブメニュー。
    private func otherAccountsMenu(for status: Status, item: StatusMenuItem) -> MenuNode<StatusMenuCommand>? {
        OtherAccount.accountsMenu(otherAccounts, title: item.title, symbolName: item.symbolName) { account in
            otherAccountNodes(for: status, as: account)
        }
    }

    /// `account`から見た投稿のメニュー。覚えている投稿があればすぐ組み、なければ開いてから探す。
    private func otherAccountNodes(for status: Status, as account: OtherAccount) -> [MenuNode<StatusMenuCommand>] {
        // まだ探していない人がいれば、その人を出せるよう、開いてから探す。
        if let known = account.known(status), !otherAccountPeople.contains(where: account.needsResolving) {
            return otherAccountItems(for: known, original: status, as: account)
        }
        return [.deferred { [self] in
            // 投稿と、投稿のほかに出る人を、そのサーバーで同時に探す。
            async let lookedUp = account.lookup(status)
            await account.resolve(otherAccountPeople)
            switch await lookedUp {
            case .found(let found):
                // 出る人の関係を、人ごとに送らずまとめて1回で読む。関係の項目は、この読み込みを待って中身を渡す。
                account.reloadRelations(otherAccountRelationIDs(in: found, as: account))
                return otherAccountItems(for: found, original: status, as: account)
            case .notFound:
                return [.action("このアカウントからは見られない投稿です", nil)]
            case .failed(let error):
                return OtherAccount.lookupFailureNodes(title: "投稿を探せませんでした", error: error, logIn: StatusMenuCommand.logIn)
            }
        }]
    }

    /// `account`から見た投稿`found`への操作。投稿のメニューと同じ組み方で、そのアカウントとして組む。
    /// - Parameter original: メニューを出した、今のアカウントでの投稿。
    private func otherAccountItems(for found: Status, original status: Status, as account: OtherAccount) -> [MenuNode<StatusMenuCommand>] {
        let root = otherAccountTree(for: found, original: status, as: account).menu(groups: otherAccountStatusGroups, includesFollowRequest: false).root
        return root?.children.map { node in
            node.map { command in
                // 組む並びから、ここで包まない命令を出す項目を除いているので、ほかの命令は来ない。
                switch command {
                case .status(let action):
                    .otherAccount(OtherAccountCommand(account: account, original: status, action: .status(found, action)))
                case .user(let user, let userCommand):
                    OtherAccountUserAction(userCommand, id: user.id, acct: user.acct).map {
                        .otherAccount(OtherAccountCommand(account: account, original: status, action: .user($0)))
                    } ?? command
                case .hashtag(let tag, let hashtagCommand):
                    .otherAccount(OtherAccountCommand(account: account, original: status, action: .hashtag(tag, hashtagCommand)))
                default:
                    command
                }
            }
        } ?? []
    }

    /// `account`から見た投稿`found`で、ユーザーのメニューの関係の項目を出す人のID。並びで人や関係の項目を出していなければ空。
    func otherAccountRelationIDs(in found: Status, as account: OtherAccount) -> [String] {
        guard let status else { return [] }
        let tree = otherAccountTree(for: found, original: status, as: account)
        guard tree.userMenu.needsRelationship else { return [] }
        // 人を集めるだけなので、ハッシュタグは組まない。組むと、ハッシュタグのリストの読み直しを、メニューを組んだときと重ねて送るため。
        return tree.menu(groups: otherAccountStatusGroups.excluding([.hashtags]), includesFollowRequest: false).shownUserIDs
    }

    /// 「別のアカウントで」の中の投稿のメニューの並び。投稿のメニューの並びから、出さない項目を除く。
    private var otherAccountStatusGroups: MenuLayout<StatusMenuItem>.Groups {
        otherAccountGroups.excluding(Self.sameForEveryAccountItems)
    }

    /// 見つけた投稿のほかに「別のアカウントで」の中に出す人。そのサーバーでのIDが分からないため、プロフィールのURLで探す。
    /// 並びで出さない人は探さない。探す通信を省き、初めて開いたメニューで待たせないため。
    private var otherAccountPeople: [Account] {
        let groups = otherAccountStatusGroups
        let items = Set((groups.main + groups.more).flatMap(\.items))
        let userGroups = otherAccountUserGroups
        guard !(userGroups.main + userGroups.more).isEmpty else { return [] }
        let boosters = items.contains(.booster) ? (booster.map { [$0] } ?? []) : []
        return boosters + (items.contains(.notifyingUser) ? notifyingAccounts : [])
    }

    /// 「別のアカウントで」の中のユーザーのメニューの並び。ユーザーのメニューの並びから、出さない項目を除く。
    private var otherAccountUserGroups: MenuLayout<UserMenuItem>.Groups {
        userMenu.excluding(UserMenuTree.otherAccountExcludedItems)
    }

    /// `account`から見た投稿`found`のメニューを、そのアカウントとして組むもの。
    /// - Parameter status: メニューを出した、今のアカウントでの投稿。人のアイコンを探すのに使う。
    private func otherAccountTree(for found: Status, original status: Status, as account: OtherAccount) -> StatusMenuTree {
        var tree = StatusMenuTree(status: found, notification: nil, now: now, linkBrowser: linkBrowser)
        tree.myAccountID = account.credential.accountID
        tree.supportsEmojiReactions = account.supportsEmojiReactions
        tree.userActions = account.userActions
        tree.userMenu = otherAccountUserGroups
        tree.hashtagMenu = hashtagMenu.excluding(Self.sameForEveryAccountHashtagItems)
        tree.hashtagActions = account.hashtagActions
        tree.booster = booster.flatMap(account.person)
        tree.notifyingAccounts = notifyingAccounts.compactMap(account.person)
        // IDはそのアカウントのサーバーのものなので、今のアカウントで同じ人をプロフィールのURLで探してアイコンを付ける。
        // IDで探すと、今のアカウントのサーバーで同じIDの別の人のアイコンを出しうる。見つからないメンションにはアイコンを付けない。
        let originalUsers = [MenuUser.account(status.displayed.account)] + status.displayed.mentions.map(MenuUser.mention) + otherAccountPeople.map(MenuUser.account)
        tree.userAvatar = { user in
            if let url = user.url, let same = originalUsers.first(where: { $0.url == url }) { return .user(same) }
            if case .account = user { return .user(user) }
            return nil
        }
        return tree
    }

    private func canReblog(_ status: Status) -> Bool {
        guard let myAccountID else { return false }
        return status.canBeReblogged(by: myAccountID)
    }

    /// コピーや翻訳に渡す本文。書式やリンクは落とし、文字だけにする。カスタム絵文字は`:shortcode:`のまま残し、サーバーが縮めて見せるURLは元の文字に戻す。
    /// 本文が空白だけならnil。
    public static func plainText(of status: Status) -> String? {
        let text = RichText.status(status).copiedText
        return text.allSatisfy(\.isWhitespace) ? nil : text
    }
}
