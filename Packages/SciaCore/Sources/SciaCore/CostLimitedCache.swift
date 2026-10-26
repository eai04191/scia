/// 重さの合計に上限を設け、あふれたら使ってから一番長いものから捨てるキャッシュ。
/// `NSCache`と違い、上限を超えたとき以外は捨てない。`NSCache`はどれをいつ捨てるかをシステムが決め、使う側では決められない。
/// iOSシミュレーターでは、アプリが裏に回った知らせを送った直後に`NSCache`が中身を捨てた。
/// 描くたびに求め直すため画面に出ているものを捨てられると読み直しになる持ち物（カスタム絵文字の静止画）に使う。
public struct CostLimitedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    public let totalCostLimit: Int
    public private(set) var totalCost = 0
    private var entries: [Key: Entry] = [:]
    private var useCount: UInt64 = 0

    public init(totalCostLimit: Int) {
        precondition(totalCostLimit > 0)
        self.totalCostLimit = totalCostLimit
    }

    public var count: Int { entries.count }

    /// 値を返し、最後に使ったものとして扱う。
    public mutating func value(forKey key: Key) -> Value? {
        guard entries[key] != nil else { return nil }
        useCount += 1
        entries[key]?.lastUse = useCount
        return entries[key]?.value
    }

    /// 上限を超えたら、使ってから一番長いものから捨てる。入れたものは最後に使ったものになるので、1つで上限を超えるときだけ捨てる。
    public mutating func setValue(_ value: Value, forKey key: Key, cost: Int) {
        let cost = max(cost, 0)
        if let old = entries[key] {
            totalCost -= old.cost
        }
        useCount += 1
        entries[key] = Entry(value: value, cost: cost, lastUse: useCount)
        totalCost += cost
        // 捨てるたびに全体から一番古いものを探す。持つのは数百個ほどで、捨てるのはあふれたときだけなので、並びを別に持たない。
        while totalCost > totalCostLimit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries[oldest.key] = nil
            totalCost -= oldest.value.cost
        }
    }
}
