import SciaCore
import UIKit

/// ユーザーのメニューの、相手との関係で中身が変わる項目（フォロー、フォローの設定、ミュート、ブロック）。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
extension UserMenuItem {
    var isRelation: Bool {
        switch self {
        case .follow, .showReblogs, .notify, .mute, .block: true
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

/// メニューを1回開く間、相手との関係を1度だけ読む。関係の項目ごとに読まないよう、同じユーザーの項目で分け合う。
@MainActor
final class UserRelationLoad {
    private let load: @MainActor () async throws -> UserRelation?
    private var task: Task<UserRelation?, any Error>?

    init(load: @escaping @MainActor () async throws -> UserRelation?) {
        self.load = load
    }

    /// 自分ならnil。
    var value: UserRelation? {
        get async throws {
            let task = task ?? Task { try await load() }
            self.task = task
            return try await task.value
        }
    }
}

extension UserMenuActions {
    /// 関係の項目。メニューを開いてから関係を読んで中身を決めるため、読む間はUIKitの読み込み中の行を出す。
    /// 自分には出さない。読めなかったら、`showsFailure`の項目にだけ押せない行で知らせ、ほかの項目は何も出さない。項目ごとに同じ知らせが並ばないようにするため。
    @MainActor
    func relationElement(_ item: UserMenuItem, load: UserRelationLoad, showsFailure: Bool) -> UIMenuElement {
        UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                do {
                    guard let relation = try await load.value else {
                        completion([])
                        return
                    }
                    completion(Self.relationElements(item, relationship: relation.relationship) { change in
                        changeRelation(change, relation)
                    })
                } catch {
                    completion(showsFailure ? [UIAction(title: "関係を読み込めませんでした", image: UIImage(systemName: "exclamationmark.triangle"), attributes: .disabled) { _ in }] : [])
                }
            }
        }
    }

    /// 関係に合わせた項目。出さないときは空。
    /// ブロックしているか、されているときは、フォローもフォローの設定もできないため出さない。フォローの設定は、フォロー中かリクエスト中の相手にだけ出す。
    @MainActor
    static func relationElements(_ item: UserMenuItem, relationship: Relationship, perform: @escaping @MainActor (UserRelationChange) -> Void) -> [UIMenuElement] {
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
        case .mute:
            if relationship.muting { return [action("ミュートを解除", "speaker.wave.2", .unmute)] }
            return [UIMenu(title: item.title, image: item.image, children: UserRelationChange.muteDurations.map { choice in
                action(choice.title, nil, .mute(choice.duration))
            })]
        case .block:
            if relationship.blocking { return [action("ブロックを解除", "hand.raised.slash", .unblock)] }
            return [action(item.title, "hand.raised", attributes: .destructive, .block)]
        case .profile, .mention, .copyHandle, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            return []
        }
    }
}

extension MenuLayout<UserMenuItem>.Groups {
    /// 関係を読めなかったことを知らせる項目。メニューで最初に出る関係の項目。
    var firstRelationItem: UserMenuItem? {
        (main + more).flatMap(\.items).first(where: \.isRelation)
    }
}
