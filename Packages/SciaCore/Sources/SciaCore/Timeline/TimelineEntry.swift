/// タイムラインに並ぶ要素。
public enum TimelineEntry: Hashable, Sendable, Identifiable {
    case status(Status)
    /// まだ読み込んでいない投稿がある区間。
    case gap(TimelineGap)
    /// 通知の一覧に並ぶ通知。
    case notification(MastodonNotification)
    /// プロフィールの一覧の上に置く、固定された投稿。同じ投稿が下の一覧にも並ぶため、IDを分ける。
    case pinned(Status)

    public enum ID: Hashable, Sendable {
        case status(Status.ID)
        case gap(String)
        case notification(MastodonNotification.ID)
        case pinned(Status.ID)
    }

    public var id: ID {
        switch self {
        case .status(let status): .status(status.id)
        case .gap(let gap): .gap(gap.id)
        case .notification(let notification): .notification(notification.id)
        case .pinned(let status): .pinned(status.id)
        }
    }

    /// 一覧に並ぶ投稿。固定された投稿は含まない。読み込みの境目や既読位置の判定に使うため。
    public var status: Status? {
        if case .status(let status) = self { status } else { nil }
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
}
