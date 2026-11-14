import Testing
@testable import SciaCore

struct StatusIDTests {
    /// Mastodonのホームは、`max_id`をRedisのスコア（倍精度）で比べ、端を含めない（app/models/feed.rb）。
    /// 今のIDは倍精度で表せる整数の範囲を超えていて、1を足しただけでは同じスコアに丸まり、`id`の投稿まで除かれるため、スコアでも上になる値を返す。
    @Test(arguments: ["117615877427659458", "117000000000000000", "9007199254740993"])
    func justAboveIsAboveInRedisScore(id: String) throws {
        let above = try #require(StatusID.justAbove(id))
        let score = try #require(Double(id))
        let aboveScore = try #require(Double(above))
        #expect(aboveScore > score)
        #expect(StatusID.isNewer(above, than: id))
    }

    /// 倍精度で表せる小さなIDでは、すぐ上の整数を返す。
    @Test func justAboveIsNextIntegerForSmallID() {
        #expect(StatusID.justAbove("5") == "6")
    }

    /// 数字でないIDと、上に値のないIDではnil。
    @Test(arguments: ["01HZXABCDEF", "", String(UInt64.max)])
    func justAboveIsNilWithoutNextValue(id: String) {
        #expect(StatusID.justAbove(id) == nil)
    }
}
