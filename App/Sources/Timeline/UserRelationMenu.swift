import SciaCore
import UIKit

/// ユーザーのメニューの、相手との関係で中身が変わる項目（フォロー、フォローの設定、メモ、ミュート、ブロック）。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
extension UserMenuItem {
    var isRelation: Bool {
        switch self {
        case .follow, .showReblogs, .notify, .note, .mute, .block, .report: true
        case .profile, .mention, .copyHandle, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari: false
        }
    }
}

/// 関係の項目を組むときの相手。
struct UserRelation {
    let accountID: String
    let acct: String
    let relationship: Relationship
}

/// 関係の項目で選んだ変更。
enum UserRelationChange {
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
    static let muteDurations: [(title: String, duration: Duration?)] = [
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
    var changesFollow: Bool {
        switch self {
        case .follow, .unfollow, .cancelFollowRequest, .block: true
        case .showReblogs, .notify, .mute, .unmute, .unblock: false
        }
    }

    /// 送れたときの知らせ。メニューを閉じると変わったことが見えないため知らせる。鍵のかかった相手のフォローは、リクエストになったことを伝える。
    func doneTitle(_ relationship: Relationship) -> String {
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

    var failureTitle: String {
        switch self {
        case .follow, .unfollow, .cancelFollowRequest: "フォローを変更できませんでした"
        case .showReblogs, .notify: "フォローの設定を変更できませんでした"
        case .mute, .unmute: "ミュートを変更できませんでした"
        case .block, .unblock: "ブロックを変更できませんでした"
        }
    }
}

/// ユーザーのメニューの相手のIDと`acct`。
struct UserIdentity {
    let id: String
    let acct: String
}

/// メニューを1回開く間、相手を1度だけ探し、相手との関係を1度だけ読む。項目ごとに探したり読んだりしないよう、同じユーザーの項目で分け合う。
/// 関係を覚えていない相手にだけ使う。覚えている相手は、`UserMenuActions.knownRelation`の関係でその場で組む。
@MainActor
final class UserRelationLoad {
    private let resolve: @MainActor () async throws -> UserIdentity
    private let load: @MainActor (UserIdentity) async throws -> UserRelation?
    private var identityTask: Task<UserIdentity, any Error>?
    private var relationTask: Task<UserRelation?, any Error>?

    init(resolve: @escaping @MainActor () async throws -> UserIdentity, load: @escaping @MainActor (UserIdentity) async throws -> UserRelation?) {
        self.resolve = resolve
        self.load = load
    }

    /// 相手のIDと`acct`。リンクのメンションのように、プロフィールのURLから探す相手もある。
    var identity: UserIdentity {
        get async throws {
            let task = identityTask ?? Task { try await resolve() }
            identityTask = task
            return try await task.value
        }
    }

    /// 相手との関係。自分ならnil。
    var value: UserRelation? {
        get async throws {
            let task = relationTask ?? Task { try await load(try await identity) }
            relationTask = task
            return try await task.value
        }
    }
}

/// 関係の項目を組むときに、手元で分かっている相手との関係。
enum KnownRelation {
    /// 自分。関係の項目を出さない。
    case myself
    case relation(UserRelation)
}

extension UserMenuActions {
    /// 関係の項目。関係を覚えている相手は、覚えている関係でその場で組む。
    /// 覚えていない相手は、読む間はUIKitの読み込み中の行を出し、読んでから中身を渡す。開く途中のサブメニューで中身が替わると動きが崩れるため、
    /// メニューを開いたときに出る人の関係をまとめて読み直し（`reloadRelations`）、次からは覚えている関係で組めるようにしている。
    /// 自分には出さない。読めなかったら、`failureSlots`の項目にだけ押せない行で知らせ、ほかの項目は何も出さない。項目ごとに同じ知らせが並ばないようにするため。
    /// 通報は関係で中身が変わらないため、関係を待たずに出す。リンクのメンションのように相手を探す必要があるときは、探してから出す。
    /// - Parameter reportableStatusID: 通報に添えられる投稿。Mastodonは通報する相手の投稿しか添えられないため、相手が書いた投稿のときだけ渡す。
    @MainActor
    func relationElements(_ item: UserMenuItem, target: UserMenuTarget, load: UserRelationLoad, failureSlots: RelationFailureSlots, reportableStatusID: String? = nil) -> [UIMenuElement] {
        func elements(_ relation: UserRelation) -> [UIMenuElement] {
            Self.relationElements(item, relationship: relation.relationship) { change in
                changeRelation(change, relation)
            } editNote: {
                editNote(relation)
            } report: {
                report(relation.accountID, relation.acct, reportableStatusID)
            }
        }
        switch knownRelation(target) {
        case .myself:
            return []
        case .relation(let relation):
            return elements(relation)
        case nil:
            break
        }
        if item == .report {
            return reportElements(target: target, load: load, showsFailure: failureSlots.resolve == .report, reportableStatusID: reportableStatusID)
        }
        return [UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                do {
                    guard let relation = try await load.value else {
                        completion([])
                        return
                    }
                    completion(elements(relation))
                } catch {
                    // 相手を探せなかったのか、探せて関係だけ読めなかったのかで、知らせる場所が違う。探した結果は分け合っているので、もう一度探しはしない。
                    let resolved = (try? await load.identity) != nil
                    completion(item == (resolved ? failureSlots.relation : failureSlots.resolve) ? [Self.relationFailureAction] : [])
                }
            }
        }]
    }

    /// 関係を覚えていない相手の通報。相手のIDが分かっていればその場で出し、相手を探すときは探してから出す。自分には出さない。
    @MainActor
    private func reportElements(target: UserMenuTarget, load: UserRelationLoad, showsFailure: Bool, reportableStatusID: String?) -> [UIMenuElement] {
        func action(_ identity: UserIdentity) -> UIAction {
            UIAction(title: UserMenuItem.report.title, image: UserMenuItem.report.image) { _ in report(identity.id, identity.acct, reportableStatusID) }
        }
        if case .account(let id, let acct) = target {
            return [action(UserIdentity(id: id, acct: acct))]
        }
        return [UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                do {
                    let identity = try await load.identity
                    if case .myself = knownRelation(.account(id: identity.id, acct: identity.acct)) {
                        completion([])
                    } else {
                        completion([action(identity)])
                    }
                } catch {
                    completion(showsFailure ? [Self.relationFailureAction] : [])
                }
            }
        }]
    }

    /// 関係を読めなかった知らせ。押せない行で出す。
    @MainActor
    private static var relationFailureAction: UIAction {
        UIAction(title: "関係を読み込めませんでした", image: UIImage(systemName: "exclamationmark.triangle"), attributes: .disabled) { _ in }
    }

    /// メニューを1回開く間、同じユーザーの項目で分け合う、相手の探し方と関係の読み方。
    @MainActor
    func relationLoad(for target: UserMenuTarget) -> UserRelationLoad {
        UserRelationLoad {
            try await resolveTarget(target)
        } load: { identity in
            try await loadRelation(target, identity)
        }
    }

    /// 関係に合わせた項目。出さないときは空。
    /// ブロックしているか、されているときは、フォローもフォローの設定もできないため出さない。フォローの設定は、フォロー中かリクエスト中の相手にだけ出す。
    @MainActor
    static func relationElements(
        _ item: UserMenuItem,
        relationship: Relationship,
        perform: @escaping @MainActor (UserRelationChange) -> Void,
        editNote: @escaping @MainActor () -> Void,
        report: @escaping @MainActor () -> Void
    ) -> [UIMenuElement] {
        func action(_ title: String, _ symbolName: String?, attributes: UIMenuElement.Attributes = [], state: UIMenuElement.State = .off, _ change: UserRelationChange) -> UIAction {
            UIAction(title: title, image: symbolName.flatMap { UIImage(systemName: $0) }, attributes: attributes, state: state) { _ in perform(change) }
        }
        let blocked = relationship.blocking || relationship.blockedBy
        let followsOrRequests = relationship.following || relationship.requested
        switch item {
        case .follow:
            guard !blocked else { return [] }
            if relationship.following { return [action("フォローを外す", "person.badge.minus", .unfollow)] }
            if relationship.requested { return [action("フォローのリクエストを取り消す", "person.badge.clock", .cancelFollowRequest)] }
            return [action(item.title, "person.badge.plus", .follow)]
        case .showReblogs:
            guard !blocked, followsOrRequests else { return [] }
            return [action(item.title, "arrow.2.squarepath", state: relationship.showingReblogs ? .on : .off, .showReblogs(!relationship.showingReblogs))]
        case .notify:
            guard !blocked, followsOrRequests else { return [] }
            return [action(item.title, "bell", state: relationship.notifying ? .on : .off, .notify(!relationship.notifying))]
        case .note:
            // ブロックしていてもメモは書ける。
            return [UIAction(title: relationship.note.isEmpty ? item.title : "メモを編集", image: item.image) { _ in editNote() }]
        case .mute:
            if relationship.muting { return [action("ミュートを解除", "speaker.wave.2", .unmute)] }
            return [UIMenu(title: item.title, image: item.image, children: UserRelationChange.muteDurations.map { choice in
                action(choice.title, nil, .mute(choice.duration))
            })]
        case .block:
            if relationship.blocking { return [action("ブロックを解除", "hand.raised.slash", .unblock)] }
            return [action(item.title, "hand.raised", attributes: .destructive, .block)]
        case .report:
            return [UIAction(title: item.title, image: item.image) { _ in report() }]
        case .profile, .mention, .copyHandle, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            return []
        }
    }
}

/// 読めなかったことを知らせる項目。項目ごとに同じ知らせが並ばないよう、失敗の種類ごとに1か所にだけ出す。
struct RelationFailureSlots: Equatable {
    /// 相手は分かって、関係だけ読めなかったときに知らせる項目。最初に出る、関係で中身が変わる項目。
    let relation: UserMenuItem?
    /// 相手を探せなかったときに知らせる項目。最初に出る、相手を探すのを待つ項目。
    let resolve: UserMenuItem?
}

extension MenuLayout<UserMenuItem>.Groups {
    /// 読めなかったことを知らせる項目。
    /// - Parameter waitsForReport: 通報も、相手を探すのを待って出す。相手のIDが分かっていれば、通報は待たずに出すので、知らせる場所にしない。
    func relationFailureSlots(waitsForReport: Bool) -> RelationFailureSlots {
        let items = (main + more).flatMap(\.items)
        let relation = items.first(where: \.dependsOnRelationship)
        return RelationFailureSlots(relation: relation, resolve: waitsForReport ? items.first { $0.dependsOnRelationship || $0 == .report } : relation)
    }
}
