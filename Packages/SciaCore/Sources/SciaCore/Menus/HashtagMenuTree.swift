public import Foundation

/// ハッシュタグのメニューの項目を押したときの操作。
public enum HashtagMenuCommand: Equatable, Sendable {
    case url(URLMenuCommand)
    /// 「すべての投稿」で、ハッシュタグのタイムラインを開く。
    case openTimeline
    /// 「投稿したユーザーの投稿」で、そのユーザーのハッシュタグの付いた投稿を開く。
    case openAccountStatuses(Account)
    /// 投稿欄に`#名前`を入れる。
    case addToCompose
    /// ミュートする。nilなら解除するまで続ける。
    case mute(Duration?)
    case unmute
    case follow
    case unfollow
    /// 自分のプロフィールの注目のハッシュタグに載せる。
    case feature
    /// 自分のプロフィールの注目のハッシュタグから外す。
    case unfeature
    /// このメニューの並びの設定の画面を開く。
    case customize
}

/// ハッシュタグのメニュー。本文のハッシュタグの長押しと、投稿のメニューの「ハッシュタグ」で、同じ並びから組む。決まりはdocs/menus.mdの「メニューの単位」にある。
/// 項目の名前、並び、出す条件、見出しはここだけが知る。押したときの動き（共有のシートを出す起点、タイムラインを開く先）は、出す場所が決める。
public struct HashtagMenuTree {
    /// `#`を除いた名前。
    public let name: String
    /// サーバーのハッシュタグのページ。分からなければ、URLの項目を押せないまま並べる。
    public let url: URL?
    /// 「投稿したユーザーの投稿」で開くユーザー。nilなら項目を出さない。
    public let account: Account?
    public let linkBrowser: LinkBrowser
    /// ミュートなど、自分の状態を読んで変える項目のためのもの。nilなら、それらの項目を出さない。
    public let actions: HashtagMenuActions?

    public init(name: String, url: URL?, account: Account?, linkBrowser: LinkBrowser, actions: HashtagMenuActions?) {
        self.name = name
        self.url = url
        self.account = account
        self.linkBrowser = linkBrowser
        self.actions = actions
    }

    /// 本文のハッシュタグの長押しで単独で出すメニュー。見出しに`#名前`を置く。出す項目がなければnil。
    @MainActor
    public func menu(groups: MenuLayout<HashtagMenuItem>.Groups) -> MenuNode<HashtagMenuCommand>? {
        let children = nodes(groups: groups)
        return children.isEmpty ? nil : .submenu("#\(name)", children)
    }

    /// 投稿のメニューの「ハッシュタグ」に並べる、`#名前`のサブメニュー。出す項目がなければnil。
    @MainActor
    public func submenu(groups: MenuLayout<HashtagMenuItem>.Groups) -> MenuNode<HashtagMenuCommand>? {
        let children = nodes(groups: groups)
        return children.isEmpty ? nil : .submenu("#\(name)", icon: .symbol(StatusMenuItem.hashtags.symbolName), children)
    }

    @MainActor
    private func nodes(groups: MenuLayout<HashtagMenuItem>.Groups) -> [MenuNode<HashtagMenuCommand>] {
        groups.nodes { item -> [MenuNode<HashtagMenuCommand>] in
            if let action = item.urlAction {
                return [action.node(url: url, linkBrowser: linkBrowser).map(HashtagMenuCommand.url)]
            }
            switch item {
            case .timeline:
                return [.action(item.title, icon: .symbol(item.symbolName), .openTimeline)]
            case .accountStatuses:
                guard let account else { return [] }
                // ほかのサーバーのユーザーなら、ユーザーのメニューの見出しと同じく、サーバー名をサブタイトルに出す。
                return [.action("@\(account.username)の投稿", subtitle: UserHeading(acct: account.acct).subtitle, icon: .symbol(item.symbolName), .openAccountStatuses(account))]
            case .addToCompose:
                guard actions?.addToCompose != nil else { return [] }
                return [.action(item.title, icon: .symbol(item.symbolName), .addToCompose)]
            case .mute:
                guard let muteActions = actions?.mute else { return [] }
                return muteNodes(muteActions, item: item)
            case .follow:
                guard let followActions = actions?.follow else { return [] }
                return followNodes(followActions, item: item)
            case .feature:
                guard let featureActions = actions?.feature else { return [] }
                return featureNodes(featureActions, item: item)
            case .customize:
                return [.action(item.title, icon: .symbol(item.symbolName), .customize)]
            // 共通の項目は、上で中身から組んだ。
            case .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
                return []
            }
        }
    }

    /// ミュートしていなければ、ユーザーのミュートと同じ期間をサブメニューで選び、ミュート中なら「ミュートを解除」にする。
    /// フィルターを覚えていれば、その場で決める。読み込み中の行を出してから中身を差し替えると、開く途中のサブメニューの動きが崩れるため。
    /// メニューを開くたびにフィルターを読み直し、別の端末やwebで変えたミュートを次に開いたときから反映する。
    /// まだ読めていなければ、読む間は読み込み中の行を出し、読めなければ押せない行で知らせる。
    @MainActor
    private func muteNodes(_ muteActions: HashtagMuteActions, item: HashtagMenuItem) -> [MenuNode<HashtagMenuCommand>] {
        let name = name
        func nodes(isMuted: Bool) -> [MenuNode<HashtagMenuCommand>] {
            if isMuted {
                return [.action("ミュートを解除", icon: .symbol("speaker.wave.2"), .unmute)]
            }
            return [.submenu(item.title, icon: .symbol(item.symbolName), UserRelationChange.muteDurations.map { choice in
                .action(choice.title, .mute(choice.duration))
            })]
        }
        let isMuted = muteActions.known(name)
        muteActions.refresh()
        if let isMuted {
            return nodes(isMuted: isMuted)
        }
        return [.deferred {
            do {
                return nodes(isMuted: try await muteActions.load(name))
            } catch {
                return [.action("ミュートを読み込めませんでした", icon: .symbol("exclamationmark.triangle"), isEnabled: false, nil)]
            }
        }]
    }
}

extension HashtagMenuTree {
    /// 載せていなければ「プロフィールで紹介する」、載せていれば「プロフィールから外す」にする。
    @MainActor
    fileprivate func featureNodes(_ featureActions: HashtagToggleActions, item: HashtagMenuItem) -> [MenuNode<HashtagMenuCommand>] {
        toggleNodes(
            featureActions,
            on: .action("プロフィールから外す", icon: .symbol(item.symbolName), .unfeature),
            off: .action("プロフィールで紹介する", icon: .symbol(item.symbolName), .feature),
            failure: "注目のハッシュタグを読み込めませんでした"
        )
    }

    /// フォローしていなければ「フォロー」、フォローしていれば「フォローを外す」にする。
    @MainActor
    fileprivate func followNodes(_ followActions: HashtagToggleActions, item: HashtagMenuItem) -> [MenuNode<HashtagMenuCommand>] {
        toggleNodes(
            followActions,
            on: .action("フォローを外す", icon: .symbol("minus.circle"), .unfollow),
            off: .action("フォロー", icon: .symbol(item.symbolName), .follow),
            failure: "フォローしているハッシュタグを読み込めませんでした"
        )
    }

    /// 状態を持つ項目の行。ミュートと同じく、覚えているハッシュタグのリストでその場で決め、メニューを開くたびに読み直す。まだ読めていなければ、読む間は読み込み中の行を出し、読めなければ押せない行で知らせる。
    /// - Parameters:
    ///   - on: タグが当てはまっている（載せている、フォローしている）ときの行。
    ///   - off: 当てはまっていないときの行。
    @MainActor
    fileprivate func toggleNodes(_ actions: HashtagToggleActions, on: MenuNode<HashtagMenuCommand>, off: MenuNode<HashtagMenuCommand>, failure: String) -> [MenuNode<HashtagMenuCommand>] {
        let name = name
        let isOn = actions.known(name)
        actions.refresh()
        if let isOn {
            return [isOn ? on : off]
        }
        return [.deferred {
            do {
                return [try await actions.load(name) ? on : off]
            } catch {
                return [.action(failure, icon: .symbol("exclamationmark.triangle"), isEnabled: false, nil)]
            }
        }]
    }
}

/// ハッシュタグのメニューの、自分の状態を読んで変える項目のためのもの。出す場所が、セッションの持ち物から組んで渡す。
public struct HashtagMenuActions {
    /// nilなら「ミュート」を出さない。
    public var mute: HashtagMuteActions?
    /// nilなら「フォロー」を出さない。
    public var follow: HashtagToggleActions?
    /// nilなら「プロフィールで紹介する」を出さない。
    public var feature: HashtagToggleActions?
    /// 投稿欄に、`#`を除いた名前のタグを入れる。nilなら「投稿欄に追加」を出さない。
    public var addToCompose: (@MainActor (String) -> Void)?

    public init(mute: HashtagMuteActions?, follow: HashtagToggleActions? = nil, feature: HashtagToggleActions? = nil, addToCompose: (@MainActor (String) -> Void)? = nil) {
        self.mute = mute
        self.follow = follow
        self.feature = feature
        self.addToCompose = addToCompose
    }

    /// 組んでも読み直さない形。メニューを開かずに組むとき（アクションバーのボタンを押せるかを決めるとき）に使う。
    /// 読み直しは、メニューを開いたときに次に開くときのために行うもので、開かないなら要らない。スクロールで投稿を組むたびに通信しないようにする。
    public var withoutRefresh: HashtagMenuActions {
        HashtagMenuActions(
            mute: mute.map { HashtagMuteActions(known: $0.known, refresh: {}, load: $0.load, mute: $0.mute, unmute: $0.unmute) },
            follow: follow?.withoutRefresh,
            feature: feature?.withoutRefresh,
            addToCompose: addToCompose
        )
    }
}

/// ハッシュタグのメニューの、タグごとに当てはまるかどうかを持つ項目（「プロフィールで紹介する」など）で、当てはまるかを読み、変える。項目は`HashtagMenuTree`が組む。
/// 決まりはdocs/menus.mdの「ハッシュタグのメニュー」にある。
public struct HashtagToggleActions {
    /// 覚えているハッシュタグのリストで決めた、`#`を除いた名前のタグが当てはまるか。まだ読めていなければnil。
    public let known: @MainActor (String) -> Bool?
    /// ハッシュタグのリストを読み直していなければ読み直す。メニューを開いたときに呼び、次に開いたときから使う。
    public let refresh: @MainActor () -> Void
    /// `#`を除いた名前のタグが当てはまるか。読み直している途中なら、それを待つ。
    public let load: @MainActor (String) async throws -> Bool
    /// 当てはまるようにする（載せる、など）。
    public let turnOn: @MainActor (String) -> Void
    /// 当てはまらないようにする（外す、など）。
    public let turnOff: @MainActor (String) -> Void

    public init(
        known: @escaping @MainActor (String) -> Bool?,
        refresh: @escaping @MainActor () -> Void,
        load: @escaping @MainActor (String) async throws -> Bool,
        turnOn: @escaping @MainActor (String) -> Void,
        turnOff: @escaping @MainActor (String) -> Void
    ) {
        self.known = known
        self.refresh = refresh
        self.load = load
        self.turnOn = turnOn
        self.turnOff = turnOff
    }

    fileprivate var withoutRefresh: HashtagToggleActions {
        HashtagToggleActions(known: known, refresh: {}, load: load, turnOn: turnOn, turnOff: turnOff)
    }
}

extension [Hashtag] {
    /// サーバーと同じ決まりでそろえた名前が同じタグがあるか。
    public func contains(named name: String) -> Bool {
        let normalized = Hashtag.normalizedName(name)
        return contains { Hashtag.normalizedName($0.name) == normalized }
    }
}

extension [FeaturedTag] {
    /// サーバーと同じ決まりでそろえた名前が同じタグ。
    public func first(named name: String) -> FeaturedTag? {
        let normalized = Hashtag.normalizedName(name)
        return first { Hashtag.normalizedName($0.name) == normalized }
    }
}

/// ハッシュタグのメニューの「ミュート」で、ミュートしているかを読み、変える。項目は`HashtagMenuTree`が組む。決まりはdocs/menus.mdの「ハッシュタグのメニュー」にある。
public struct HashtagMuteActions {
    /// 覚えている自分のフィルターで決めた、`#`を除いた名前のタグをミュートしているか。フィルターをまだ読めていなければnil。
    public let known: @MainActor (String) -> Bool?
    /// 自分のフィルターを読み直していなければ読み直す。メニューを開いたときに呼び、次に開いたときから使う。
    public let refresh: @MainActor () -> Void
    /// `#`を除いた名前のタグをミュートしているか。フィルターを読み直している途中なら、それを待つ。
    public let load: @MainActor (String) async throws -> Bool
    /// ミュートする。nilなら解除するまで続ける。
    public let mute: @MainActor (String, Duration?) -> Void
    /// ミュートを解除する。解く条件は、解除するときにフィルターを読み直して決める。メニューを組んだときに覚えていた条件で消すと、
    /// その後に別の端末やwebで同じフィルターに足した条件まで、フィルターごと消してしまうため。
    public let unmute: @MainActor (String) -> Void

    public init(
        known: @escaping @MainActor (String) -> Bool?,
        refresh: @escaping @MainActor () -> Void,
        load: @escaping @MainActor (String) async throws -> Bool,
        mute: @escaping @MainActor (String, Duration?) -> Void,
        unmute: @escaping @MainActor (String) -> Void
    ) {
        self.known = known
        self.refresh = refresh
        self.load = load
        self.mute = mute
        self.unmute = unmute
    }
}
