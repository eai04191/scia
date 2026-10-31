/// 長い本文を切る行数。決まりはdocs/long-post.mdにある。
public struct BodyTruncation: Sendable, Equatable {
    /// 折り返した行数がこれを超えたら切る。
    public let threshold: Int
    /// 切ったときに出す行数。切り始める行数より多くはしない。
    public let visibleLines: Int

    /// 切り始める行数が0なら切らないので、nilを返す。
    public init?(threshold: Int, lines: Int) {
        guard threshold > 0 else { return nil }
        self.threshold = threshold
        visibleLines = min(max(lines, 1), threshold)
    }

    /// 本文を出す行数。切り始める行数を超えていれば切ったときの行数、超えていなければ0（切らない）。
    public func lineLimit(exceedsThreshold: Bool) -> Int {
        exceedsThreshold ? visibleLines : 0
    }
}

/// 「続きを読む」で広げた本文。
///
/// 投稿は元の投稿のIDで覚え、同じ投稿のブーストや通知の行、引用の囲みもそろえる。Xの投稿は投稿のIDで覚える。覚えるのはアプリを起動している間だけ。
public struct LongBodyExpansion: Sendable, Equatable {
    /// 広げたものを見分けるキー。
    public enum Key: Hashable, Sendable {
        case status(Status.ID)
        case xPost(String)
    }

    private var expanded: Set<Key> = []

    public init() {}

    public func isExpanded(_ key: Key) -> Bool {
        expanded.contains(key)
    }

    public mutating func expand(_ key: Key) {
        expanded.insert(key)
    }

    /// 投稿の本文（引用の囲みに出す引用元の本文も）に当てる行数。切らないならnil。
    /// スレッドの画面で開いている投稿、注意書きのある投稿、広げた投稿は切らない。ブーストなら元の投稿で決める。
    public func truncation(forBodyOf status: Status, isThreadFocus: Bool, rule: BodyTruncation?) -> BodyTruncation? {
        let shown = status.displayed
        guard !isThreadFocus, shown.spoilerText.isEmpty, !isExpanded(.status(shown.id)) else { return nil }
        return rule
    }

    /// Xの投稿の囲みの本文に当てる行数。切らないならnil。
    /// - Parameter isThreadFocus: 囲みを出している投稿が、スレッドの画面で開いている投稿か。
    public func truncation(forXPost id: String, isThreadFocus: Bool, rule: BodyTruncation?) -> BodyTruncation? {
        guard !isThreadFocus, !isExpanded(.xPost(id)) else { return nil }
        return rule
    }
}
