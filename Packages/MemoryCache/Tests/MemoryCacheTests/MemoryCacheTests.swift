import Testing
@testable import MemoryCache

struct MemoryCacheTests {
    private final class Item {
        let name: String

        init(_ name: String) {
            self.name = name
        }
    }

    /// 上限から外した値も、ほかで持たれている間は同じものを返し、上限には数え直さない。
    @Test func evictedValueInUseIsReturnedWithoutCountingAgain() {
        var cache = MemoryCache<String, Item>(totalCostLimit: 10)
        let held = Item("a")
        cache.setValue(held, forKey: "a", cost: 6)
        cache.setValue(Item("b"), forKey: "b", cost: 6)
        #expect(cache.count == 1)
        #expect(cache.value(forKey: "a") === held)
        #expect(cache.count == 1)
        #expect(cache.totalCost == 6)
    }

    /// 上限から外した値は、ほかで持たれていなければ返さない。
    @Test func evictedValueNotInUseIsGone() {
        var cache = MemoryCache<String, Item>(totalCostLimit: 10)
        cache.setValue(Item("a"), forKey: "a", cost: 6)
        cache.setValue(Item("b"), forKey: "b", cost: 6)
        #expect(cache.value(forKey: "a") == nil)
        #expect(!cache.contains("a"))
    }

    /// 手放すと、ほかで持たれている値だけを返す。
    @Test func releasingUnusedKeepsValuesInUse() {
        var cache = MemoryCache<String, Item>(totalCostLimit: 100)
        let held = Item("held")
        cache.setValue(held, forKey: "held", cost: 1)
        cache.setValue(Item("unused"), forKey: "unused", cost: 1)
        cache.releaseUnused()
        #expect(cache.value(forKey: "held") === held)
        #expect(cache.value(forKey: "unused") == nil)
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
        #expect(cache.totalCostLimit == 100)
    }

    /// 同じキーに入れ直したら、前の値は使用中でも返さない。
    @Test func replacingAKeyReturnsTheNewValue() {
        var cache = MemoryCache<String, Item>(totalCostLimit: 10)
        let old = Item("old")
        cache.setValue(old, forKey: "a", cost: 1)
        cache.releaseUnused()
        let new = Item("new")
        cache.setValue(new, forKey: "a", cost: 1)
        #expect(cache.value(forKey: "a") === new)
        #expect(old.name == "old")
    }

    /// 持っているかを調べても、使ったものとして扱わない。
    @Test func containsDoesNotCountAsUse() {
        var cache = MemoryCache<String, Item>(totalCostLimit: 10)
        cache.setValue(Item("a"), forKey: "a", cost: 4)
        cache.setValue(Item("b"), forKey: "b", cost: 4)
        #expect(cache.contains("a"))
        cache.setValue(Item("c"), forKey: "c", cost: 4)
        #expect(!cache.contains("a"))
        #expect(cache.contains("b"))
    }

    /// 入れ続けても、上限に数えている値と使用中の値のほかは返さない。
    @Test func onlyRetainedValuesRemainAfterManyInsertions() {
        var cache = MemoryCache<Int, Item>(totalCostLimit: 1)
        for index in 0..<1_000 {
            cache.setValue(Item("\(index)"), forKey: index, cost: 1)
        }
        let live = (0..<1_000).filter { cache.contains($0) }
        #expect(live == [999])
    }

    /// 使用中の値が上限に数えている値よりずっと多くても、入れるたびに表全体を見直さない。3つのストアはメインアクターで入れるため。
    @Test func manyValuesInUseDoNotMakeEveryInsertionScanTheTable() {
        var cache = MemoryCache<Int, Item>(totalCostLimit: 1)
        var held: [Item] = []
        for index in 0..<2_000 {
            let item = Item("\(index)")
            held.append(item)
            cache.setValue(item, forKey: index, cost: 1)
        }
        let cleanups = cache.referenceCleanupCount
        for index in 2_000..<2_100 {
            let item = Item("\(index)")
            held.append(item)
            cache.setValue(item, forKey: index, cost: 1)
        }
        // 見直したあとに残った行の倍まで増えるまでは見直さないので、2,000行から100行増やすあいだには見直さない。
        #expect(cache.referenceCleanupCount == cleanups)
        #expect(held.count == 2_100)
    }
}
