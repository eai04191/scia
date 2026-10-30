/// ユーザーのメニューの、相手との関係で中身が変わる項目（フォロー、フォローの設定、メモ、ミュート、ブロック）。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
extension UserMenuItem {
    public var isRelation: Bool {
        switch self {
        case .follow, .showReblogs, .notify, .note, .mute, .block, .report: true
        case .profile, .mention, .copyHandle, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari: false
        }
    }
}

/// 関係の項目を組むときの相手。
public struct UserRelation: Sendable {
    public let accountID: String
    public let acct: String
    public let relationship: Relationship

    public init(accountID: String, acct: String, relationship: Relationship) {
        self.accountID = accountID
        self.acct = acct
        self.relationship = relationship
    }
}

/// 関係の項目で選んだ変更。
public enum UserRelationChange: Sendable {
    case follow
    case unfollow
    case cancelFollowRequest
    case showReblogs(Bool)
    case notify(Bool)
    /// nilなら解除するまで続ける。
    case mute(Duration?)
    case unmute
    case block
    case unblock

    /// ミュートの期間の選択肢。Mastodonのwebと同じ並び。
    public static let muteDurations: [(title: String, duration: Duration?)] = [
        ("無期限", nil),
        ("5分", .seconds(5 * 60)),
        ("30分", .seconds(30 * 60)),
        ("1時間", .seconds(60 * 60)),
        ("6時間", .seconds(6 * 60 * 60)),
        ("1日", .seconds(24 * 60 * 60)),
        ("3日", .seconds(3 * 24 * 60 * 60)),
        ("7日", .seconds(7 * 24 * 60 * 60)),
    ]
}

extension UserRelationChange {
    /// フォローそのものを変える。フォロワー数が変わるため、開いているプロフィールのアカウントを読み直す。
    public var changesFollow: Bool {
        switch self {
        case .follow, .unfollow, .cancelFollowRequest, .block: true
        case .showReblogs, .notify, .mute, .unmute, .unblock: false
        }
    }

    /// 送れたときの知らせ。メニューを閉じると変わったことが見えないため知らせる。鍵のかかった相手のフォローは、リクエストになったことを伝える。
    public func doneTitle(_ relationship: Relationship) -> String {
        switch self {
        case .follow: relationship.requested ? "フォローをリクエストしました" : "フォローしました"
        case .unfollow: "フォローを外しました"
        case .cancelFollowRequest: "リクエストを取り消しました"
        case .showReblogs(let shows): shows ? "ブーストを表示します" : "ブーストを表示しません"
        case .notify(let notifies): notifies ? "投稿を通知します" : "投稿を通知しません"
        case .mute: "ミュートしました"
        case .unmute: "ミュートを解除しました"
        case .block: "ブロックしました"
        case .unblock: "ブロックを解除しました"
        }
    }

    public var failureTitle: String {
        switch self {
        case .follow, .unfollow, .cancelFollowRequest: "フォローを変更できませんでした"
        case .showReblogs, .notify: "フォローの設定を変更できませんでした"
        case .mute, .unmute: "ミュートを変更できませんでした"
        case .block, .unblock: "ブロックを変更できませんでした"
        }
    }
}

/// ユーザーのメニューの相手のIDと`acct`。
public struct UserIdentity: Sendable {
    public let id: String
    public let acct: String

    public init(id: String, acct: String) {
        self.id = id
        self.acct = acct
    }
}

/// メニューを1回開く間、相手を1度だけ探し、相手との関係を1度だけ読む。項目ごとに探したり読んだりしないよう、同じユーザーの項目で分け合う。
/// 関係を覚えていない相手にだけ使う。覚えている相手は、`UserMenuActions.knownRelation`の関係でその場で組む。
@MainActor
public final class UserRelationLoad {
    private let resolve: @MainActor () async throws -> UserIdentity
    private let load: @MainActor (UserIdentity) async throws -> UserRelation?
    private var identityTask: Task<UserIdentity, any Error>?
    private var relationTask: Task<UserRelation?, any Error>?

    public init(resolve: @escaping @MainActor () async throws -> UserIdentity, load: @escaping @MainActor (UserIdentity) async throws -> UserRelation?) {
        self.resolve = resolve
        self.load = load
    }

    /// 相手のIDと`acct`。リンクのメンションのように、プロフィールのURLから探す相手もある。
    public var identity: UserIdentity {
        get async throws {
            let task = identityTask ?? Task { try await resolve() }
            identityTask = task
            return try await task.value
        }
    }

    /// 相手との関係。自分ならnil。
    public var value: UserRelation? {
        get async throws {
            let task = relationTask ?? Task { try await load(try await identity) }
            relationTask = task
            return try await task.value
        }
    }
}

/// 関係の項目を組むときに、手元で分かっている相手との関係。
public enum KnownRelation: Sendable {
    /// 自分。関係の項目を出さない。
    case myself
    case relation(UserRelation)
}

/// 読めなかったことを知らせる項目。項目ごとに同じ知らせが並ばないよう、失敗の種類ごとに1か所にだけ出す。
public struct RelationFailureSlots: Equatable, Sendable {
    /// 相手は分かって、関係だけ読めなかったときに知らせる項目。最初に出る、関係で中身が変わる項目。
    public let relation: UserMenuItem?
    /// 相手を探せなかったときに知らせる項目。最初に出る、相手を探すのを待つ項目。
    public let resolve: UserMenuItem?

    public init(relation: UserMenuItem?, resolve: UserMenuItem?) {
        self.relation = relation
        self.resolve = resolve
    }
}

extension MenuLayout<UserMenuItem>.Groups {
    /// 読めなかったことを知らせる項目。
    /// - Parameter waitsForReport: 通報も、相手を探すのを待って出す。相手のIDが分かっていれば、通報は待たずに出すので、知らせる場所にしない。
    public func relationFailureSlots(waitsForReport: Bool) -> RelationFailureSlots {
        let items = (main + more).flatMap(\.items)
        let relation = items.first(where: \.dependsOnRelationship)
        return RelationFailureSlots(relation: relation, resolve: waitsForReport ? items.first { $0.dependsOnRelationship || $0 == .report } : relation)
    }
}
