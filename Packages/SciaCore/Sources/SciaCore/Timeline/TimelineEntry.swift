public import Foundation

/// タイムラインに並ぶ要素。
public enum TimelineEntry: Hashable, Sendable, Identifiable {
    case status(Status)
    /// まだ読み込んでいない投稿がある区間。
    case gap(TimelineGap)
    /// 通知のタイムラインに並ぶ通知。
    case notification(MastodonNotification)
    /// プロフィールのタイムラインの上に置く、固定された投稿。同じ投稿が下のタイムラインにも並ぶため、IDを分ける。
    case pinned(Status)
    /// 読めなかった投稿や通知。
    case unreadable(UnreadableItem)
    /// 人のリストに並ぶアカウント。
    case account(Account)
    /// 保留中の通知のリストに並ぶ、1人分のまとまり。
    case notificationRequest(NotificationRequest)
    /// 検索の結果に並ぶ、投稿と人のほかの行。
    case search(SearchRow)

    public enum ID: Hashable, Sendable {
        case status(Status.ID)
        case gap(String)
        case notification(MastodonNotification.ID)
        case pinned(Status.ID)
        case unreadable(String)
        case account(String)
        case notificationRequest(String)
        case search(String)
    }

    public var id: ID {
        switch self {
        case .status(let status): .status(status.id)
        case .gap(let gap): .gap(gap.id)
        case .notification(let notification): .notification(notification.id)
        case .pinned(let status): .pinned(status.id)
        case .unreadable(let item): .unreadable(item.id)
        case .account(let account): .account(account.id)
        case .notificationRequest(let request): .notificationRequest(request.id)
        case .search(let row): .search(row.id)
        }
    }

    /// クラッシュの記録と隔離に使う、この行が描く投稿のID。ブーストは元の投稿のIDにする。同じ投稿を別の人がブーストした行も同じように落ちるため。
    public var quarantinableStatusID: Status.ID? {
        switch self {
        case .status(let status), .pinned(let status): status.displayed.id
        case .notification(let notification): notification.status?.displayed.id
        case .gap, .unreadable, .account, .notificationRequest, .search: nil
        }
    }

    /// タイムラインに並ぶ投稿。固定された投稿は含まない。読み込みの境目や既読位置の判定に使うため。
    public var status: Status? {
        if case .status(let status) = self { status } else { nil }
    }

    /// 投稿として並ぶ項目の投稿。固定された投稿も含む。通知の対象の投稿は含まない。
    public var postStatus: Status? {
        switch self {
        case .status(let status), .pinned(let status): status
        case .gap, .notification, .unreadable, .account, .notificationRequest, .search: nil
        }
    }

    /// 項目が指す投稿。投稿の項目ならその投稿、通知なら対象の投稿。ギャップやフォローの通知などではnil。
    public var targetStatus: Status? {
        switch self {
        case .status(let status), .pinned(let status): status
        case .notification(let notification): notification.status
        case .gap, .unreadable, .account, .notificationRequest, .search: nil
        }
    }

    /// 項目に出る人。投稿した人、ブーストした人、通知した人（まとめた通知なら並べた人）、通知の対象の投稿の人、人のリストの人、保留中の通知を送ってきた人。
    public var accounts: [Account] {
        switch self {
        case .status(let status), .pinned(let status): [status.account, status.reblog?.account].compactMap(\.self)
        case .notification(let notification): notification.sampleAccounts + [notification.status?.account, notification.status?.reblog?.account].compactMap(\.self)
        case .account(let account): [account]
        case .notificationRequest(let request): [request.account]
        case .gap, .unreadable, .search: []
        }
    }
}

extension Sequence<TimelineEntry> {
    /// 項目に出る人から、そのIDのアカウントを探す。
    public func account(withID id: Account.ID) -> Account? {
        lazy.flatMap(\.accounts).first { $0.id == id }
    }

    /// 項目が指す投稿（ブーストなら元の投稿も）のメンションから、リンク先が`url`の人を探す。
    public func mention(withURL url: URL) -> Mention? {
        lazy.compactMap(\.targetStatus)
            .flatMap { [$0, $0.reblog].compactMap(\.self) }
            .flatMap(\.mentions)
            .first { $0.url == url }
    }
}

/// サーバーから届いたが、読めなかった投稿や通知。IDが読めたものだけをタイムラインに並べ、並びと、続きを読む位置に使う。
/// 読めなかったことを隠さず、ブラウザで開けるようにするため。
public struct UnreadableItem: Hashable, Sendable, Identifiable {
    public let id: String
    /// ブラウザで開くページ。投稿ならその投稿、通知なら対象の投稿。読めなければnil。
    public let url: URL?
    /// 読めなかった通知のまとまりの、読んだ範囲の最も古い通知のID。続きを読む位置に使う。まとまりでなければnil。
    public let pageMinID: String?
    /// 表示中にクラッシュしたため隠している投稿か。docs/crash-quarantine.md
    public let isCrashQuarantined: Bool

    public init(id: String, url: URL?, pageMinID: String? = nil, isCrashQuarantined: Bool = false) {
        self.id = id
        self.url = url
        self.pageMinID = pageMinID
        self.isCrashQuarantined = isCrashQuarantined
    }
}

/// 読み込んだ投稿の間で、まだ読み込んでいない区間。両端のIDは含まない。
public struct TimelineGap: Hashable, Sendable {
    /// 片側から読み込んで区間が縮んでも同じギャップとして扱えるよう、作ったときに決めて引き継ぐ。
    public let id: String
    /// 区間の新しい側の端。この投稿より古い投稿が欠けている。
    public let newerID: Status.ID
    /// 区間の古い側の端。この投稿より新しい投稿が欠けている。
    public let olderID: Status.ID

    public init(newerID: Status.ID, olderID: Status.ID) {
        self.init(id: "gap-\(olderID)-\(newerID)", newerID: newerID, olderID: olderID)
    }

    private init(id: String, newerID: Status.ID, olderID: Status.ID) {
        self.id = id
        self.newerID = newerID
        self.olderID = olderID
    }

    func narrowed(newerID: Status.ID? = nil, olderID: Status.ID? = nil) -> TimelineGap {
        TimelineGap(id: id, newerID: newerID ?? self.newerID, olderID: olderID ?? self.olderID)
    }

    func widened(olderID: Status.ID) -> TimelineGap {
        TimelineGap(id: id, newerID: newerID, olderID: olderID)
    }
}
