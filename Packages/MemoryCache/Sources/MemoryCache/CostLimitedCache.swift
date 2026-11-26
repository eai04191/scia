/// 重さの合計に上限を設け、あふれたら使ってから一番長いものから捨てるキャッシュ。
/// `NSCache`と違い、上限を超えたとき以外は捨てない。`NSCache`はどれをいつ捨てるかをシステムが決め、使う側では決められない。
/// iOSシミュレーターでは、アプリが裏に回った通知を送った直後に`NSCache`が中身を捨てた。
/// 使うたびにキャッシュから求め直すため、使っているものを捨てられると作り直しになる持ち物に使う。
///
/// 使った順は、キーでつないだ双方向リストで持つ。使う、入れる、一番古いものを捨てるのは、どれも持っている数によらない時間で済む。
public struct CostLimitedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        /// 1つ前に使ったもの。一番古いものならnil。
        var older: Key?
        /// 1つあとに使ったもの。最後に使ったものならnil。
        var newer: Key?
    }

    public let totalCostLimit: Int
    public private(set) var totalCost = 0
    private var entries: [Key: Entry] = [:]
    /// 使ってから一番長いもの。
    private var oldest: Key?
    /// 最後に使ったもの。
    private var newest: Key?

    public init(totalCostLimit: Int) {
        precondition(totalCostLimit > 0)
        self.totalCostLimit = totalCostLimit
    }

    public var count: Int { entries.count }

    /// 持っている値。使ったものとして扱わない。
    public var values: [Value] { entries.values.map(\.value) }

    /// 持っているか。使ったものとして扱わない。
    public func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    /// 値を返し、最後に使ったものとして扱う。
    public mutating func value(forKey key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        unlink(key)
        link(key)
        return entry.value
    }

    /// 上限を超えたら、使ってから一番長いものから捨てる。入れたものは最後に使ったものになるので、1つで上限を超えるときだけ捨てる。
    /// - Returns: 捨てたもののキー。
    @discardableResult
    public mutating func setValue(_ value: Value, forKey key: Key, cost: Int) -> [Key] {
        let cost = max(cost, 0)
        if let old = entries[key] {
            totalCost -= old.cost
            unlink(key)
        }
        entries[key] = Entry(value: value, cost: cost)
        link(key)
        totalCost += cost
        var evicted: [Key] = []
        while totalCost > totalCostLimit, let key = oldest, let entry = entries[key] {
            unlink(key)
            entries[key] = nil
            totalCost -= entry.cost
            evicted.append(key)
        }
        return evicted
    }

    /// `key`を使った順のリストから外す。値は残す。
    private mutating func unlink(_ key: Key) {
        guard let entry = entries[key] else { return }
        if let older = entry.older {
            entries[older]?.newer = entry.newer
        } else {
            oldest = entry.newer
        }
        if let newer = entry.newer {
            entries[newer]?.older = entry.older
        } else {
            newest = entry.older
        }
        entries[key]?.older = nil
        entries[key]?.newer = nil
    }

    /// `key`を最後に使ったものとしてリストの末尾につなぐ。リストから外してあるものに使う。
    private mutating func link(_ key: Key) {
        entries[key]?.older = newest
        entries[key]?.newer = nil
        if let newest {
            entries[newest]?.newer = key
        } else {
            oldest = key
        }
        newest = key
    }
}
