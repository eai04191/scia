public import Foundation

/// ストリーミングで一覧に届いた新着の流れの速さ。直近1分に届いた数で表す。一覧を引っぱったときに見せる。
public struct ArrivalRate: Sendable, Equatable {
    private static let window: TimeInterval = 60
    /// 届いた時刻。古い順。1分より前のものは、次に届いたときに捨てる。
    private var arrivals: [Date] = []

    public init() {}

    public mutating func record(at date: Date) {
        arrivals.removeAll { date.timeIntervalSince($0) >= Self.window }
        arrivals.append(date)
    }

    /// `now`までの1分に届いた数。
    public func perMinute(at now: Date) -> Int {
        arrivals.count { now.timeIntervalSince($0) < Self.window }
    }
}
