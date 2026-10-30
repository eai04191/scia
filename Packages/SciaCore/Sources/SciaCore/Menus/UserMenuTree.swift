public import Foundation

/// ユーザーのメニューの項目を押したときの操作。
public enum UserMenuCommand: Sendable {
    case url(URLMenuCommand)
    case openProfile
    /// 投稿欄で、カーソルの位置に`@acct`を入れる。
    case mention
    /// サーバー名を付けた`@username@domain`の形でコピーする。
    case copyHandle
    /// 関係の項目で選んだ変更を送る。
    case changeRelation(UserRelationChange, UserRelation)
    /// 相手のプロフィールに書く、自分にしか見えないメモのシートを開く。
    case editNote(UserRelation)
    /// 通報のシートを開く。投稿のメニューから開いたときは、添えられる相手の投稿のIDを渡す。
    case report(accountID: String, acct: String, statusID: String?)
}

/// ユーザーのメニューの、メンション、ハンドルをコピー、関係の項目で使う相手。
public enum UserMenuTarget: Sendable {
    /// APIの`Account`や`mentions`から取ったIDと`acct`。そのまま使える。
    case account(id: String, acct: String)
    /// 本文や自己紹介のメンションのリンク。APIの`mentions`にないリンクでは、パーサーはリンクの文字列を`acct`の代わりにするが、
    /// Mastodonはほかのサーバーのユーザーでもリンクの文字列からサーバー名を省くため、そのままでは別のユーザーを指す。プロフィールのURLでアカウントを引いて`acct`を決める。
    /// - Parameter shownAcct: 見つからなかったときの知らせに出す、リンクの文字列から取った名前。
    case profileURL(URL, shownAcct: String)
}

/// ユーザーのメニューを出す相手。
public struct UserMenuSubject: Sendable {
    /// 見出しと、サブメニューにせず直接並べるときの名前に出す`acct`。
    public let acct: String
    /// URLの項目で扱う、プロフィールのページのURL。
    public let url: URL?
    /// メンション、ハンドルをコピー、関係の項目で使う相手。
    public let target: UserMenuTarget

    public init(_ user: MenuUser) {
        acct = user.acct
        url = user.url
        target = .account(id: user.id, acct: user.acct)
    }

    /// 本文や自己紹介のメンションのリンク。相手は、プロフィールのURLで探す。
    public init(mentionLink url: URL, acct: String) {
        self.acct = acct
        self.url = url
        target = .profileURL(url, shownAcct: acct)
    }

    /// 相手のID。リンクのメンションでは、探すまで分からないのでnil。
    public var id: String? {
        if case .account(let id, _) = target { id } else { nil }
    }
}

/// ユーザーのメニューの、投稿欄とログイン中のサーバーに頼る項目（メンション、ハンドルをコピー、関係の項目）の動き。項目は`UserMenuTree`が組む。
/// セッションが作り、画面を組み立てる側が渡す。渡されていない画面では、これらの項目を出さない。
public struct UserMenuActions {
    /// 投稿欄で、カーソルの位置に`@acct`を入れる。
    public let mention: @MainActor (UserMenuTarget) -> Void
    /// サーバー名を付けた`@username@domain`の形でコピーし、コピーできたら`notify`を呼ぶ。
    public let copyHandle: @MainActor (UserMenuTarget, _ notify: @escaping @MainActor () -> Void) -> Void
    /// 相手のIDと`acct`を決める。リンクのメンションは、プロフィールのURLから探す。見つからなければ投げる。
    public let resolveTarget: @MainActor (UserMenuTarget) async throws -> UserIdentity
    /// `resolveTarget`で決めた相手と自分の関係を読む。覚えている関係を読み直している途中なら、それを待つ。自分ならnil。
    public let loadRelation: @MainActor (UserMenuTarget, UserIdentity) async throws -> UserRelation?
    /// 手元で分かっている相手との関係。相手のIDが分からないか、関係を覚えていなければnil。
    public let knownRelation: @MainActor (UserMenuTarget) -> KnownRelation?
    /// 相手たちとの関係をまとめて1回で読み直し、覚えておく。自分は除く。
    public let reloadRelations: @MainActor ([String]) -> Void
    /// 関係の項目で選んだ変更を送る。取り消しにくい変更は、確かめてから送る。
    public let changeRelation: @MainActor (UserRelationChange, UserRelation) -> Void
    /// 相手のプロフィールに書く、自分にしか見えないメモのシートを開く。
    public let editNote: @MainActor (UserRelation) -> Void
    /// 通報のシートを開く。投稿のメニューから開いたときは、添えられる相手の投稿のIDを渡す。
    public let report: @MainActor (_ accountID: String, _ acct: String, _ statusID: String?) -> Void
    /// セッションで読んだアカウント。メンションされたユーザーのように、アイコンのURLが手元にない相手のアイコンを出すのに使う。
    public let accounts: AccountCache

    public init(
        mention: @escaping @MainActor (UserMenuTarget) -> Void,
        copyHandle: @escaping @MainActor (UserMenuTarget, _ notify: @escaping @MainActor () -> Void) -> Void,
        resolveTarget: @escaping @MainActor (UserMenuTarget) async throws -> UserIdentity,
        loadRelation: @escaping @MainActor (UserMenuTarget, UserIdentity) async throws -> UserRelation?,
        knownRelation: @escaping @MainActor (UserMenuTarget) -> KnownRelation?,
        reloadRelations: @escaping @MainActor ([String]) -> Void,
        changeRelation: @escaping @MainActor (UserRelationChange, UserRelation) -> Void,
        editNote: @escaping @MainActor (UserRelation) -> Void,
        report: @escaping @MainActor (_ accountID: String, _ acct: String, _ statusID: String?) -> Void,
        accounts: AccountCache
    ) {
        self.mention = mention
        self.copyHandle = copyHandle
        self.resolveTarget = resolveTarget
        self.loadRelation = loadRelation
        self.knownRelation = knownRelation
        self.reloadRelations = reloadRelations
        self.changeRelation = changeRelation
        self.editNote = editNote
        self.report = report
        self.accounts = accounts
    }
}

/// ユーザーのメニュー。投稿のメニューのサブメニュー、アイコンや人の一覧の行、本文や自己紹介のメンション、プロフィール画面の「…」で、同じ並びから組む。
/// 決まりはdocs/menus.mdの「ユーザーのメニュー」にある。項目の名前、並び、出す条件、見出しはここだけが知る。
/// 押したときの動き（共有のシートを出す起点、プロフィールを開く先）と、人のアイコンの画像は、出す場所が決める。
@MainActor
public struct UserMenuTree {
    public let subject: UserMenuSubject
    /// セッションの、メンション、ハンドルをコピー、関係の項目を組むもの。nilなら、これらの項目を出さない。
    public let actions: UserMenuActions?
    /// 開く場所の設定。メニューを組むときの値で決める。
    public let linkBrowser: LinkBrowser
    /// 通報に添えられる投稿。Mastodonは通報する相手の投稿しか添えられないため、長押しした投稿を相手が書いたときだけ渡す。
    public var reportableStatusID: String?

    public init(subject: UserMenuSubject, actions: UserMenuActions?, linkBrowser: LinkBrowser, reportableStatusID: String? = nil) {
        self.subject = subject
        self.actions = actions
        self.linkBrowser = linkBrowser
        self.reportableStatusID = reportableStatusID
    }

    /// 投稿のメニューに置く、`@acct`のサブメニュー。サブメニューの項目にその人のアイコンを付け、中の「プロフィール」は記号のままにする。同じ顔が2つ並ばないようにするため。
    /// 中身が1つで「その他」が空なら、サブメニューにせず「@acctのプロフィール」のように直接並べる。出す項目がなければnil。
    /// 関係の読み直しは、投稿のメニューに出る人をまとめて1回で頼むため、ここでは頼まない。
    /// - Parameter avatar: その人のアイコン。
    public func submenu(groups: MenuLayout<UserMenuItem>.Groups, avatar: MenuAvatar) -> MenuNode<UserMenuCommand>? {
        // 関係の項目は読んでから中身が決まり、名前に相手を入れられないため、1つだけでもサブメニューにする。
        if groups.more.isEmpty, groups.main.count == 1, let only = groups.main.first?.items, only.count == 1, !only[0].isRelation {
            // サブメニューの項目に付けるアイコンがないので、「プロフィール」にその人のアイコンを付ける。
            return Items(tree: self, groups: groups, inSubmenu: false, offersProfile: true, profileAvatar: avatar).nodes(for: only[0]).first
        }
        let children = nodes(groups: groups, offersProfile: true, profileAvatar: nil)
        guard !children.isEmpty else { return nil }
        let heading = UserHeading(acct: subject.acct)
        return .submenu(heading.title, subtitle: heading.subtitle, icon: .avatar(avatar, fallbackSymbol: nil), children)
    }

    /// 単独で出すメニュー（アイコンや人の一覧の行、本文や自己紹介のメンション）。サブメニューの項目がないので、「プロフィール」にその人のアイコンを付ける。
    /// 単独で出すメニューの見出しでは、UIKitがサブタイトルを描かないため、サーバー名を2行目に置く。出す項目がなければnil。
    /// - Parameter avatar: 「プロフィール」に付けるその人のアイコン。出せなければ記号を付ける。
    public func menu(groups: MenuLayout<UserMenuItem>.Groups, avatar: MenuAvatar?) -> MenuNode<UserMenuCommand>? {
        let children = nodes(groups: groups, offersProfile: true, profileAvatar: avatar)
        guard !children.isEmpty else { return nil }
        let heading = UserHeading(acct: subject.acct)
        return .submenu(heading.subtitle.map { "\(heading.title)\n\($0)" } ?? heading.title, children)
    }

    /// プロフィール画面のナビゲーションバーの「…」に出すメニュー。開いているプロフィールを開くだけの「プロフィール」は出さない。
    /// 見出しは置かない。開いているプロフィールの人のメニューなので、見れば分かるため。出す項目がなければnil。
    public func profileScreenMenu(groups: MenuLayout<UserMenuItem>.Groups) -> MenuNode<UserMenuCommand>? {
        let children = nodes(groups: groups, offersProfile: false, profileAvatar: nil)
        return children.isEmpty ? nil : .submenu("", children)
    }

    /// 単独で出すメニューとプロフィール画面のメニューで、開くたびに関係を読み直す相手のID。
    /// 関係で中身が変わる項目を出していなければ読み直さないのでnil。リンクのメンションは、相手を探すまでIDが分からないため、
    /// ここではなく、相手を探したあとに関係を読むところ（`UserMenuActions.loadRelation`）で読み直す。
    public func relationReloadID(groups: MenuLayout<UserMenuItem>.Groups) -> String? {
        guard let id = subject.id, groups.needsRelationship else { return nil }
        return id
    }

    private func nodes(groups: MenuLayout<UserMenuItem>.Groups, offersProfile: Bool, profileAvatar: MenuAvatar?) -> [MenuNode<UserMenuCommand>] {
        let items = Items(tree: self, groups: groups, inSubmenu: true, offersProfile: offersProfile, profileAvatar: profileAvatar)
        return groups.nodes { items.nodes(for: $0) }
    }

    /// メニューを1回組む間の、項目ごとの組み方。
    @MainActor
    private struct Items {
        let tree: UserMenuTree
        /// 見出しのあるメニューに並べる。falseなら、投稿のメニューに直接並べるため、名前に相手を入れる。
        let inSubmenu: Bool
        /// 「プロフィール」を出すか。
        let offersProfile: Bool
        /// 「プロフィール」に付けるアイコン。nilなら記号を付ける。
        let profileAvatar: MenuAvatar?
        /// メニューを1回開く間、関係の項目で分け合う、相手の探し方と関係の読み方。
        let load: UserRelationLoad?
        let failureSlots: RelationFailureSlots

        init(tree: UserMenuTree, groups: MenuLayout<UserMenuItem>.Groups, inSubmenu: Bool, offersProfile: Bool, profileAvatar: MenuAvatar?) {
            self.tree = tree
            self.inSubmenu = inSubmenu
            self.offersProfile = offersProfile
            self.profileAvatar = profileAvatar
            load = tree.actions.map { UserMenuTree.relationLoad(for: tree.subject.target, actions: $0) }
            // 知らせる項目は、組む並びから決める。1項目だけ組むときに、出さない項目で知らせて空のメニューにならないため。
            // リンクのメンションは相手を探す必要があるので、通報も探すのを待って出す。
            failureSlots = groups.relationFailureSlots(waitsForReport: tree.subject.id == nil)
        }

        func nodes(for item: UserMenuItem) -> [MenuNode<UserMenuCommand>] {
            let subject = tree.subject
            if let action = item.urlAction {
                return [action.node(title: inSubmenu ? nil : UserMenuTree.inlineTitle(of: action, acct: subject.acct), url: subject.url, linkBrowser: tree.linkBrowser).map(UserMenuCommand.url)]
            }
            switch item {
            case .profile:
                guard offersProfile else { return [] }
                let icon: MenuIcon = profileAvatar.map { .avatar($0, fallbackSymbol: item.symbolName) } ?? .symbol(item.symbolName)
                return [.action(inSubmenu ? item.title : "@\(subject.acct)のプロフィール", icon: icon, .openProfile)]
            case .mention:
                guard tree.actions != nil else { return [] }
                return [.action(inSubmenu ? item.title : "@\(subject.acct)にメンション", icon: .symbol(item.symbolName), .mention)]
            case .copyHandle:
                guard tree.actions != nil else { return [] }
                return [.action(inSubmenu ? item.title : "@\(subject.acct)のハンドルをコピー", icon: .symbol(item.symbolName), .copyHandle)]
            case .follow, .showReblogs, .notify, .note, .mute, .block, .report:
                guard let actions = tree.actions, let load else { return [] }
                return tree.relationNodes(item, actions: actions, load: load, failureSlots: failureSlots)
            // 共通の項目は、上で中身から組んだ。
            case .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
                return []
            }
        }
    }

    /// サブメニューにせず投稿のメニューに直接並べるときの、ユーザーの共通の項目の名前。
    private static func inlineTitle(of action: URLMenuAction, acct: String) -> String {
        switch action {
        case .copyLink: "@\(acct)のリンクをコピー"
        case .share: "@\(acct)を共有"
        case .openInBrowser: "@\(acct)をブラウザで開く"
        case .openInDefaultBrowser: "@\(acct)を既定のブラウザで開く"
        case .openInAppSafari: "@\(acct)をアプリ内のSafariで開く"
        }
    }
}

// MARK: - 関係の項目

extension UserMenuTree {
    /// 関係の項目。関係を覚えている相手は、覚えている関係でその場で組む。
    /// 覚えていない相手は、読む間は読み込み中の行を出し、読んでから中身を渡す。開く途中のサブメニューで中身が替わると動きが崩れるため、
    /// メニューを開いたときに出る人の関係をまとめて読み直し（`reloadRelations`）、次からは覚えている関係で組めるようにしている。
    /// 自分には出さない。読めなかったら、`failureSlots`の項目にだけ押せない行で知らせ、ほかの項目は何も出さない。項目ごとに同じ知らせが並ばないようにするため。
    /// 通報は関係で中身が変わらないため、関係を待たずに出す。リンクのメンションのように相手を探す必要があるときは、探してから出す。
    func relationNodes(_ item: UserMenuItem, actions: UserMenuActions, load: UserRelationLoad, failureSlots: RelationFailureSlots) -> [MenuNode<UserMenuCommand>] {
        let reportableStatusID = reportableStatusID
        switch actions.knownRelation(subject.target) {
        case .myself:
            return []
        case .relation(let relation):
            return Self.relationNodes(item, relation: relation, reportableStatusID: reportableStatusID)
        case nil:
            break
        }
        if item == .report {
            return reportNodes(actions: actions, load: load, showsFailure: failureSlots.resolve == .report)
        }
        return [.deferred {
            do {
                guard let relation = try await load.value else { return [] }
                return Self.relationNodes(item, relation: relation, reportableStatusID: reportableStatusID)
            } catch {
                // 相手を探せなかったのか、探せて関係だけ読めなかったのかで、知らせる場所が違う。探した結果は分け合っているので、もう一度探しはしない。
                let resolved = (try? await load.identity) != nil
                return item == (resolved ? failureSlots.relation : failureSlots.resolve) ? [Self.relationFailureNode] : []
            }
        }]
    }

    /// 関係を覚えていない相手の通報。相手のIDが分かっていればその場で出し、相手を探すときは探してから出す。自分には出さない。
    private func reportNodes(actions: UserMenuActions, load: UserRelationLoad, showsFailure: Bool) -> [MenuNode<UserMenuCommand>] {
        let reportableStatusID = reportableStatusID
        func node(_ identity: UserIdentity) -> MenuNode<UserMenuCommand> {
            .action(UserMenuItem.report.title, icon: .symbol(UserMenuItem.report.symbolName), .report(accountID: identity.id, acct: identity.acct, statusID: reportableStatusID))
        }
        if case .account(let id, let acct) = subject.target {
            return [node(UserIdentity(id: id, acct: acct))]
        }
        return [.deferred {
            do {
                let identity = try await load.identity
                if case .myself = actions.knownRelation(.account(id: identity.id, acct: identity.acct)) {
                    return []
                }
                return [node(identity)]
            } catch {
                return showsFailure ? [Self.relationFailureNode] : []
            }
        }]
    }

    /// 関係を読めなかった知らせ。押せない行で出す。
    private static var relationFailureNode: MenuNode<UserMenuCommand> {
        .action("関係を読み込めませんでした", icon: .symbol("exclamationmark.triangle"), isEnabled: false, nil)
    }

    /// メニューを1回開く間、同じユーザーの項目で分け合う、相手の探し方と関係の読み方。
    static func relationLoad(for target: UserMenuTarget, actions: UserMenuActions) -> UserRelationLoad {
        UserRelationLoad {
            try await actions.resolveTarget(target)
        } load: { identity in
            try await actions.loadRelation(target, identity)
        }
    }

    /// 関係に合わせた項目。出さないときは空。
    /// ブロックしているか、されているときは、フォローもフォローの設定もできないため出さない。フォローの設定は、フォロー中かリクエスト中の相手にだけ出す。
    /// - Parameter reportableStatusID: 通報に添えられる投稿。
    public static func relationNodes(_ item: UserMenuItem, relation: UserRelation, reportableStatusID: String? = nil) -> [MenuNode<UserMenuCommand>] {
        let relationship = relation.relationship
        func node(_ title: String, _ symbolName: String?, isDestructive: Bool = false, isSelected: Bool = false, _ change: UserRelationChange) -> MenuNode<UserMenuCommand> {
            .action(title, icon: symbolName.map(MenuIcon.symbol), isDestructive: isDestructive, isSelected: isSelected, .changeRelation(change, relation))
        }
        let blocked = relationship.blocking || relationship.blockedBy
        let followsOrRequests = relationship.following || relationship.requested
        switch item {
        case .follow:
            guard !blocked else { return [] }
            if relationship.following { return [node("フォローを外す", "person.badge.minus", .unfollow)] }
            if relationship.requested { return [node("フォローのリクエストを取り消す", "person.badge.clock", .cancelFollowRequest)] }
            return [node(item.title, "person.badge.plus", .follow)]
        case .showReblogs:
            guard !blocked, followsOrRequests else { return [] }
            return [node(item.title, "arrow.2.squarepath", isSelected: relationship.showingReblogs, .showReblogs(!relationship.showingReblogs))]
        case .notify:
            guard !blocked, followsOrRequests else { return [] }
            return [node(item.title, "bell", isSelected: relationship.notifying, .notify(!relationship.notifying))]
        case .note:
            // ブロックしていてもメモは書ける。
            return [.action(relationship.note.isEmpty ? item.title : "メモを編集", icon: .symbol(item.symbolName), .editNote(relation))]
        case .mute:
            if relationship.muting { return [node("ミュートを解除", "speaker.wave.2", .unmute)] }
            return [.submenu(item.title, icon: .symbol(item.symbolName), UserRelationChange.muteDurations.map { choice in
                node(choice.title, nil, .mute(choice.duration))
            })]
        case .block:
            if relationship.blocking { return [node("ブロックを解除", "hand.raised.slash", .unblock)] }
            return [node(item.title, "hand.raised", isDestructive: true, .block)]
        case .report:
            return [.action(item.title, icon: .symbol(item.symbolName), .report(accountID: relation.accountID, acct: relation.acct, statusID: reportableStatusID))]
        case .profile, .mention, .copyHandle, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            return []
        }
    }
}
