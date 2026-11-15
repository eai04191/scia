import MemoryCache
import Testing

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

    /// 捨てたもののキーを、捨てた順に返す。
    @Test func returnsEvictedKeys() {
        var cache = CostLimitedCache<String, Int>(totalCostLimit: 10)
        #expect(cache.setValue(1, forKey: "a", cost: 4).isEmpty)
        #expect(cache.setValue(2, forKey: "b", cost: 4).isEmpty)
        #expect(cache.setValue(3, forKey: "c", cost: 8) == ["a", "b"])
    }

    /// 持っているかを調べても、使ったものとして扱わない。
    @Test func containsDoesNotCountAsUse() {
        var cache = CostLimitedCache<String, Int>(totalCostLimit: 10)
        cache.setValue(1, forKey: "a", cost: 4)
        cache.setValue(2, forKey: "b", cost: 4)
        #expect(cache.contains("a"))
        cache.setValue(3, forKey: "c", cost: 4)
        #expect(!cache.contains("a"))
        #expect(cache.contains("b"))
    }

    /// 真ん中や先頭のものを使ったり入れ直したりしても、使った順を保ち、その順に捨てる。
    @Test func keepsUseOrderAcrossUsesAndReplacements() {
        var cache = CostLimitedCache<String, Int>(totalCostLimit: 4)
        for (index, key) in ["a", "b", "c", "d"].enumerated() {
            cache.setValue(index, forKey: key, cost: 1)
        }
        _ = cache.value(forKey: "b")
        cache.setValue(9, forKey: "a", cost: 1)
        _ = cache.value(forKey: "d")
        // 使った順は古いものから c, b, a, d。
        #expect(cache.setValue(10, forKey: "e", cost: 1) == ["c"])
        #expect(cache.setValue(11, forKey: "f", cost: 2) == ["b", "a"])
        #expect(cache.value(forKey: "a") == nil)
        #expect(cache.value(forKey: "d") == 3)
        #expect(cache.count == 3)
        #expect(cache.totalCost == 4)
    }
}
