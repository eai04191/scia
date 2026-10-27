public import Foundation

/// 予約できる日時の決まり。決まりはdocs/compose.mdの「予約投稿」にある。
public enum ScheduledPosting {
    /// サーバーが受け付ける、今から予約の日時までの短さの下限（`ScheduledStatus::MINIMUM_OFFSET`）。これ以内の日時は422で断られる。
    /// https://github.com/mastodon/mastodon/blob/main/app/models/scheduled_status.rb
    public static let minimumLeadTime: TimeInterval = 5 * 60

    /// 予約できる。サーバーは今から5分以内を断り、過去の日時は断らずにすぐ投稿するため、どちらも送らない。
    public static func accepts(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSince(now) > minimumLeadTime
    }

    /// 選べる最も早い日時。秒を切り上げ、分の単位で選ぶ日時の選び方でも、受け付けられる日時だけが選べるようにする。
    public static func earliestDate(now: Date, calendar: Calendar) -> Date {
        ceiling(now.addingTimeInterval(minimumLeadTime + 1), to: .minute, calendar: calendar)
    }

    /// 予約を足した直後の日時。1時間より先の、いちばん近い正時（10時20分なら12時）。
    public static func defaultDate(now: Date, calendar: Calendar) -> Date {
        ceiling(now.addingTimeInterval(60 * 60), to: .hour, calendar: calendar)
    }

    /// `date`を`component`の区切りに切り上げる。ちょうど区切りなら、そのまま。
    private static func ceiling(_ date: Date, to component: Calendar.Component, calendar: Calendar) -> Date {
        guard let start = calendar.dateInterval(of: component, for: date)?.start, start != date else { return date }
        return calendar.date(byAdding: component, value: 1, to: start) ?? date
    }
}
