/// 上限付きのキャッシュ（`CostLimitedCache`）に、使用中の値を覚える表を足したもの。
///
/// 入れた値は、上限を超えたときに使ってから一番長いものから捨て、`releaseUnused()`で全部手放す。
/// ただし、ほかで持たれている間（画面や層が描いている間）は、捨てたあとも同じ値を返す。
/// 捨てた値を求め直して作り直すと、作り直した分を入れ直してほかの値を押し出し、使用中の値同士で作り直しを繰り返すため。
/// 使用中かは、値への参照を持たない表で調べるので、値はクラスに限る。
public struct MemoryCache<Key: Hashable, Value: AnyObject> {
    private final class WeakReference {
        weak var value: Value?

        init(_ value: Value) {
            self.value = value
        }
    }

    private var retained: CostLimitedCache<Key, Value>
    /// 入れた値すべての、参照を持たない表。`retained`から捨てたあとも、ほかで持たれている間は値が残る。
    private var references: [Key: WeakReference] = [:]
    /// 表の行がこの数を超えたら、値が解放された行を消す。消したあとに残った行の倍にする。
    private var referenceCleanupThreshold = 64
    /// 値が解放された行を消すために、表全体を見直した回数。入れるたびに見直さないことを、テストで確かめる。
    private(set) var referenceCleanupCount = 0

    public init(totalCostLimit: Int) {
        retained = CostLimitedCache(totalCostLimit: totalCostLimit)
    }

    public var totalCostLimit: Int { retained.totalCostLimit }

    /// 上限に数えている値の重さの合計。使用中で、上限から外したあとも残っている値は数えない。
    public var totalCost: Int { retained.totalCost }

    /// 上限に数えている値の数。
    public var count: Int { retained.count }

    /// 値を返す。上限に数えている値なら、最後に使ったものとして扱う。上限から外した値は、使用中の間だけ返し、上限に数え直さない。
    public mutating func value(forKey key: Key) -> Value? {
        if let value = retained.value(forKey: key) {
            return value
        }
        guard let reference = references[key] else { return nil }
        guard let value = reference.value else {
            references[key] = nil
            return nil
        }
        return value
    }

    /// 返せる値を持っているか。使ったものとして扱わない。
    public func contains(_ key: Key) -> Bool {
        retained.contains(key) || references[key]?.value != nil
    }

    /// 上限を超えたら、使ってから一番長いものから上限に数えるのをやめる。
    /// - Returns: 上限から外した値のキー。使用中なら、外したあとも`value(forKey:)`で返す。
    @discardableResult
    public mutating func setValue(_ value: Value, forKey key: Key, cost: Int) -> [Key] {
        references[key] = WeakReference(value)
        let evicted = retained.setValue(value, forKey: key, cost: cost)
        removeReleasedReferences()
        return evicted
    }

    /// 上限に数えている値をすべて手放す。使用中の値は、ほかで持たれている間は返す。メモリ警告を受けたときに呼ぶ。
    public mutating func releaseUnused() {
        retained = CostLimitedCache(totalCostLimit: retained.totalCostLimit)
        removeReleasedReferences()
    }

    /// 値が解放された表の行を消す。消すたびに全体を見るので、行が前に消したあとに残った数の倍を超えたときだけ消す。
    /// 上限に数えている値の数で決めると、使用中の値がそれより多いとき、消しても減らないまま、入れるたびに全体を見直すため。
    private mutating func removeReleasedReferences() {
        guard references.count > referenceCleanupThreshold else { return }
        references = references.filter { $0.value.value != nil }
        referenceCleanupCount += 1
        referenceCleanupThreshold = max(references.count * 2, 64)
    }
}
