import Testing
@testable import SciaCore

struct CostLimitedCacheTests {
    @Test func keepsValuesWithinTheLimit() {
        var cache = CostLimitedCache<String, Int>(totalCostLimit: 10)
        cache.setValue(1, forKey: "a", cost: 4)
        cache.setValue(2, forKey: "b", cost: 4)
        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "b") == 2)
        #expect(cache.totalCost == 8)
    }

    /// あふれたら使ってから一番長いものから捨て、入れた順では捨てない。
    @Test func evictsTheLeastRecentlyUsedFirst() {
        var cache = CostLimitedCache<String, Int>(totalCostLimit: 10)
        cache.setValue(1, forKey: "a", cost: 4)
        cache.setValue(2, forKey: "b", cost: 4)
        _ = cache.value(forKey: "a")
        cache.setValue(3, forKey: "c", cost: 4)
        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "b") == nil)
        #expect(cache.value(forKey: "c") == 3)
        #expect(cache.totalCost == 8)
    }

    /// 同じキーに入れ直したときは、前の重さを数えない。
    @Test func replacingAKeyReplacesItsCost() {
        var cache = CostLimitedCache<String, Int>(totalCostLimit: 10)
        cache.setValue(1, forKey: "a", cost: 6)
        cache.setValue(2, forKey: "a", cost: 3)
        #expect(cache.totalCost == 3)
        #expect(cache.count == 1)
        #expect(cache.value(forKey: "a") == 2)
    }

    /// 1つで上限を超えるものは持たない。ほかのものもそれを入れるために捨てる。
    @Test func valueLargerThanTheLimitIsNotKept() {
        var cache = CostLimitedCache<String, Int>(totalCostLimit: 10)
        cache.setValue(1, forKey: "a", cost: 4)
        cache.setValue(2, forKey: "b", cost: 11)
        #expect(cache.value(forKey: "b") == nil)
        #expect(cache.totalCost == 0)
    }
}
