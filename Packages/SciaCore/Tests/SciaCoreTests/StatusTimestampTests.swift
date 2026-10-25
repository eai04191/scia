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

    private let japan = Locale(identifier: "ja_JP")

    private func text(secondsAgo seconds: TimeInterval, _ style: StatusTimeStyle) -> String {
        StatusTimestamp.text(for: now.addingTimeInterval(-seconds), now: now, style: style, calendar: calendar, locale: japan)
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

    /// 時と分の並べ方は端末の12時間制の設定に、日付の並べ方は地域に従う。
    @Test(arguments: [
        ("ja_JP@hours=h12", ["午後12:00", "10/14 午後11:59", "2025/12/19 午後12:00"]),
        // 英語の書式は、時刻と午前午後のあいだを、狭い改行しない空白（U+202F）で空ける。
        ("en_US", ["12:00\u{202F}PM", "10/14, 11:59\u{202F}PM", "12/19/2025, 12:00\u{202F}PM"]),
        ("ja_DE", ["12:00", "14.10. 23:59", "19.12.2025 12:00"]),
    ] as [(String, [String])])
    func absoluteFollowsLocale(identifier: String, expected: [String]) {
        let locale = Locale(identifier: identifier)
        let texts = [0, 12 * 3_600 + 60, 86_400 * 300].map { (seconds: TimeInterval) in
            StatusTimestamp.text(for: now.addingTimeInterval(-seconds), now: now, style: .absolute, calendar: calendar, locale: locale)
        }
        #expect(texts == expected)
    }

    /// 端末の暦が和暦なら、年を元号で書く。年の数だけを書いて西暦と取り違えることはない。
    @Test func japaneseCalendarWritesTheEra() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = calendar.timeZone
        let date = now.addingTimeInterval(-86_400 * 300)

        #expect(StatusTimestamp.text(for: date, now: now, style: .absolute, calendar: japanese, locale: japan) == "R7/12/19 12:00")
        #expect(StatusTimestamp.text(for: date, now: now, style: .relative, calendar: japanese, locale: japan) == "R7/12/19")
    }

    /// VoiceOverでは、「10/14」を分数のように読まないよう、月を言葉で書く。
    @Test(arguments: [
        (0.0, StatusTimeStyle.absolute, "12:00"),
        (12 * 3_600 + 60, .absolute, "10月14日 23:59"),
        (86_400 * 300, .absolute, "2025年12月19日 12:00"),
        (86_400 * 7, .relative, "10月8日"),
        (60, .relative, "1分"),
    ] as [(TimeInterval, StatusTimeStyle, String)])
    func accessibilityTextSpellsTheMonth(secondsAgo: TimeInterval, style: StatusTimeStyle, expected: String) {
        let text = StatusTimestamp.accessibilityText(for: now.addingTimeInterval(-secondsAgo), now: now, style: style, calendar: calendar, locale: japan)
        #expect(text == expected)
    }

    @Test func nameStylesOrderParts() {
        #expect(StatusNameStyle.nameAndAcct.parts == [.displayName, .acct])
        #expect(StatusNameStyle.acctAndName.parts == [.acct, .displayName])
        #expect(StatusNameStyle.nameOnly.parts == [.displayName])
        #expect(StatusNameStyle.acctOnly.parts == [.acct])
    }
}
