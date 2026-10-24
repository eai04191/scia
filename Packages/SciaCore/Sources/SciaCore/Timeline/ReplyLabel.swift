/// 返信の投稿の本文の上に出す、返信先を示すラベル。行の高さを受け取った時点で決めるため、返信先の投稿は読まず、投稿に含まれる情報だけで決める。
public enum ReplyLabel: Hashable, Sendable {
    /// 投稿した人が、自分の投稿に続けて書いた。
    case continuation
    /// ログイン中のアカウントへの返信。
    case toMe
    /// ほかの人への返信。返信先のハンドルを持つ。
    case toAccount(acct: String)
    /// 返信先のアカウントがメンションになく、ハンドルが分からない返信。返信からメンションを消したときに起きる。
    case unknownAccount

    /// 返信でなければnil。
    public init?(status: Status, myAccountID: String?) {
        guard status.inReplyToId != nil else { return nil }
        let accountID = status.inReplyToAccountId
        if accountID == status.account.id {
            self = .continuation
        } else if let accountID, accountID == myAccountID {
            self = .toMe
        } else if let acct = status.mentions.first(where: { $0.id == accountID })?.acct {
            self = .toAccount(acct: acct)
        } else {
            self = .unknownAccount
        }
    }
}

/// 一覧で隣り合う行が、返信と返信先の関係にあるか。アイコン同士を線でつなぐのに使う。
public struct ReplyConnection: Hashable, Sendable {
    /// すぐ上の行とつながる。
    public var above = false
    /// すぐ下の行とつながる。
    public var below = false
    /// すぐ上の行が、この行の返信先。スレッドでは、線で返信先が分かるためラベルを出さない。
    public var parentIsAbove = false

    public init(above: Bool = false, below: Bool = false, parentIsAbove: Bool = false) {
        self.above = above
        self.below = below
        self.parentIsAbove = parentIsAbove
    }

    /// 並びの順の要素から、つながる行だけを返す。
    /// ブーストと固定の投稿、投稿でない行はつながない。ブーストの行は、アイコンの上にブーストした人の行があり、線がその行を横切るため。
    public static func connections(in entries: [TimelineEntry]) -> [TimelineEntry.ID: ReplyConnection] {
        var result: [TimelineEntry.ID: ReplyConnection] = [:]
        for (upper, lower) in zip(entries, entries.dropFirst()) {
            guard let upperStatus = connectable(upper), let lowerStatus = connectable(lower) else { continue }
            let lowerRepliesToUpper = lowerStatus.inReplyToId == upperStatus.id
            guard lowerRepliesToUpper || upperStatus.inReplyToId == lowerStatus.id else { continue }
            result[upper.id, default: ReplyConnection()].below = true
            result[lower.id, default: ReplyConnection()].above = true
            if lowerRepliesToUpper {
                result[lower.id, default: ReplyConnection()].parentIsAbove = true
            }
        }
        return result
    }

    private static func connectable(_ entry: TimelineEntry) -> Status? {
        guard case .status(let status) = entry, status.reblog == nil else { return nil }
        return status
    }
}
