public import Foundation

/// タイムラインに並ぶ要素。
public enum TimelineEntry: Hashable, Sendable, Identifiable {
    case status(Status)
    /// まだ読み込んでいない投稿がある区間。
    case gap(TimelineGap)
    /// 通知の一覧に並ぶ通知。
    case notification(MastodonNotification)
    /// プロフィールの一覧の上に置く、固定された投稿。同じ投稿が下の一覧にも並ぶため、IDを分ける。
    case pinned(Status)
    /// 読めなかった投稿や通知。
    case unreadable(UnreadableItem)

    public enum ID: Hashable, Sendable {
        case status(Status.ID)
        case gap(String)
        case notification(MastodonNotification.ID)
        case pinned(Status.ID)
        case unreadable(String)
    }

    public var id: ID {
        switch self {
        case .status(let status): .status(status.id)
        case .gap(let gap): .gap(gap.id)
        case .notification(let notification): .notification(notification.id)
        case .pinned(let status): .pinned(status.id)
        case .unreadable(let item): .unreadable(item.id)
        }
    }

    /// 一覧に並ぶ投稿。固定された投稿は含まない。読み込みの境目や既読位置の判定に使うため。
    public var status: Status? {
        if case .status(let status) = self { status } else { nil }
    }
}

/// サーバーから届いたが、読めなかった投稿や通知。IDが読めたものだけを一覧に並べ、並びと、続きを読む位置に使う。
/// 読めなかったことを隠さず、ブラウザで開けるようにするため。
public struct UnreadableItem: Hashable, Sendable, Identifiable {
    public let id: String
    /// ブラウザで開くページ。投稿ならその投稿、通知なら対象の投稿。読めなければnil。
    public let url: URL?

    public init(id: String, url: URL?) {
        self.id = id
        self.url = url
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
