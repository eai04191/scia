import Foundation
import Testing
@testable import SciaCore

struct StatusTimestampTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        return calendar
    }()

    /// 2026/10/15 12:00（日本時間）
    private let now = Date(timeIntervalSince1970: 1_792_033_200)

    private func text(secondsAgo seconds: TimeInterval, _ style: StatusTimeStyle) -> String {
        StatusTimestamp.text(for: now.addingTimeInterval(-seconds), now: now, style: style, calendar: calendar)
    }

    @Test(arguments: [
        (0.0, "0秒"),
        (59, "59秒"),
        (60, "1分"),
        (3_599, "59分"),
        (3_600, "1時間"),
        (86_399, "23時間"),
        (86_400, "1日"),
        (86_400 * 6, "6日"),
        // 1週間より前は日付にする。
        (86_400 * 7, "10/8"),
        // 去年より前は年も書く。
        (86_400 * 300, "2025/12/19"),
    ] as [(TimeInterval, String)])
    func relative(secondsAgo: TimeInterval, expected: String) {
        #expect(text(secondsAgo: secondsAgo, .relative) == expected)
    }

    /// 端末の時計が遅れていると、届いた投稿が未来の時刻になることがある。
    @Test func futureDateIsTreatedAsNow() {
        #expect(text(secondsAgo: -30, .relative) == "0秒")
    }

    @Test(arguments: [
        (0.0, "12:00"),
        // 同じ日のうちは時刻だけにする。
        (12 * 3_600, "0:00"),
        (12 * 3_600 + 60, "10/14 23:59"),
        (86_400 * 300, "2025/12/19 12:00"),
    ] as [(TimeInterval, String)])
    func absolute(secondsAgo: TimeInterval, expected: String) {
        #expect(text(secondsAgo: secondsAgo, .absolute) == expected)
    }

    @Test func nameStylesOrderParts() {
        #expect(StatusNameStyle.nameAndAcct.parts == [.displayName, .acct])
        #expect(StatusNameStyle.acctAndName.parts == [.acct, .displayName])
        #expect(StatusNameStyle.nameOnly.parts == [.displayName])
        #expect(StatusNameStyle.acctOnly.parts == [.acct])
    }
}
