import Foundation
import Testing
@testable import SciaCore

/// 直近1分に届いた数を流れの速さにする。
struct ArrivalRateTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsArrivalsWithinLastMinute() {
        var rate = ArrivalRate()
        rate.record(at: start)
        rate.record(at: start.addingTimeInterval(30))
        rate.record(at: start.addingTimeInterval(50))

        #expect(rate.perMinute(at: start.addingTimeInterval(55)) == 3)
        #expect(rate.perMinute(at: start.addingTimeInterval(60)) == 2)
        #expect(rate.perMinute(at: start.addingTimeInterval(200)) == 0)
    }

    /// 1分より前に届いたものは、次に届いたときに捨て、溜め続けない。
    @Test func forgetsOldArrivals() {
        var rate = ArrivalRate()
        rate.record(at: start)
        rate.record(at: start.addingTimeInterval(120))

        var expected = ArrivalRate()
        expected.record(at: start.addingTimeInterval(120))
        #expect(rate == expected)
    }
}
