public import Foundation

/// ハッシュタグのメニューの項目を押したときの操作。
public enum HashtagMenuCommand: Equatable, Sendable {
    case url(URLMenuCommand)
    /// 「すべての投稿」で、ハッシュタグのタイムラインを開く。
    case openTimeline
    /// 「投稿したユーザーの投稿」で、そのユーザーのハッシュタグの付いた投稿を開く。
    case openAccountStatuses(Account)
    /// ミュートする。nilなら解除するまで続ける。
    case mute(Duration?)
    case unmute
    /// 自分のプロフィールの注目のハッシュタグに載せる。
    case feature
    /// 自分のプロフィールの注目のハッシュタグから外す。
    case unfeature
    /// このメニューの並びの設定の画面を開く。
    case customize
}

/// ハッシュタグのメニュー。本文のハッシュタグの長押しと、投稿のメニューの「ハッシュタグ」で、同じ並びから組む。決まりはdocs/menus.mdの「メニューの単位」にある。
/// 項目の名前、並び、出す条件、見出しはここだけが知る。押したときの動き（共有のシートを出す起点、一覧を開く先）は、出す場所が決める。
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
            case .mute:
                guard let muteActions = actions?.mute else { return [] }
                return muteNodes(muteActions, item: item)
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
    /// ミュートと同じく、覚えている一覧でその場で決め、メニューを開くたびに読み直す。まだ読めていなければ、読む間は読み込み中の行を出し、読めなければ押せない行で知らせる。
    @MainActor
    fileprivate func featureNodes(_ featureActions: HashtagFeatureActions, item: HashtagMenuItem) -> [MenuNode<HashtagMenuCommand>] {
        let name = name
        func nodes(isFeatured: Bool) -> [MenuNode<HashtagMenuCommand>] {
            isFeatured
                ? [.action("プロフィールから外す", icon: .symbol(item.symbolName), .unfeature)]
                : [.action("プロフィールで紹介する", icon: .symbol(item.symbolName), .feature)]
        }
        let isFeatured = featureActions.known(name)
        featureActions.refresh()
        if let isFeatured {
            return nodes(isFeatured: isFeatured)
        }
        return [.deferred {
            do {
                return nodes(isFeatured: try await featureActions.load(name))
            } catch {
                return [.action("注目のハッシュタグを読み込めませんでした", icon: .symbol("exclamationmark.triangle"), isEnabled: false, nil)]
            }
        }]
    }
}

/// ハッシュタグのメニューの、自分の状態を読んで変える項目のためのもの。出す場所が、セッションの持ち物から組んで渡す。
public struct HashtagMenuActions {
    /// nilなら「ミュート」を出さない。
    public var mute: HashtagMuteActions?
    /// nilなら「プロフィールで紹介する」を出さない。
    public var feature: HashtagFeatureActions?

    public init(mute: HashtagMuteActions?, feature: HashtagFeatureActions? = nil) {
        self.mute = mute
        self.feature = feature
    }
}

/// ハッシュタグのメニューの「プロフィールで紹介する」で、自分のプロフィールに載せているかを読み、変える。項目は`HashtagMenuTree`が組む。
/// 決まりはdocs/menus.mdの「ハッシュタグのメニュー」にある。
public struct HashtagFeatureActions {
    /// 覚えている自分の注目のハッシュタグで決めた、`#`を除いた名前のタグを載せているか。まだ読めていなければnil。
    public let known: @MainActor (String) -> Bool?
    /// 自分の注目のハッシュタグを読み直していなければ読み直す。メニューを開いたときに呼び、次に開いたときから使う。
    public let refresh: @MainActor () -> Void
    /// `#`を除いた名前のタグを載せているか。読み直している途中なら、それを待つ。
    public let load: @MainActor (String) async throws -> Bool
    /// 載せる。
    public let feature: @MainActor (String) -> Void
    /// 外す。外すIDは、外すときに読み直した一覧で決める。
    public let unfeature: @MainActor (String) -> Void

    public init(
        known: @escaping @MainActor (String) -> Bool?,
        refresh: @escaping @MainActor () -> Void,
        load: @escaping @MainActor (String) async throws -> Bool,
        feature: @escaping @MainActor (String) -> Void,
        unfeature: @escaping @MainActor (String) -> Void
    ) {
        self.known = known
        self.refresh = refresh
        self.load = load
        self.feature = feature
        self.unfeature = unfeature
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
