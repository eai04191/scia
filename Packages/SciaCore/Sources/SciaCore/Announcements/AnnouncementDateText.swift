public import Foundation

/// お知らせの先頭の行に出す日時。決まりはdocs/announcements.mdの「行」にある。
public enum AnnouncementDateText {
    /// 期間があれば期間を、なければ公開した日時を書く。終日なら日付だけ、始まりと終わりが同じ日なら終わりの日付を省き、今年の日付なら年を省く。
    public static func text(for announcement: Announcement, now: Date, calendar: Calendar) -> String {
        guard let start = announcement.startsAt, let end = announcement.endsAt else {
            return "\(date(announcement.publishedAt, now: now, calendar: calendar)) \(time(announcement.publishedAt, calendar: calendar))"
        }
        let sameDay = calendar.isDate(start, inSameDayAs: end)
        if announcement.allDay {
            return sameDay ? date(start, now: now, calendar: calendar) : "\(date(start, now: now, calendar: calendar))〜\(date(end, now: now, calendar: calendar))"
        }
        let startText = "\(date(start, now: now, calendar: calendar)) \(time(start, calendar: calendar))"
        let endText = sameDay ? time(end, calendar: calendar) : "\(date(end, now: now, calendar: calendar)) \(time(end, calendar: calendar))"
        return "\(startText)〜\(endText)"
    }

    private static func date(_ date: Date, now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let monthDay = "\(parts.month ?? 0)月\(parts.day ?? 0)日"
        guard parts.year != calendar.component(.year, from: now) else { return monthDay }
        return "\(parts.year ?? 0)年\(monthDay)"
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return "\(parts.hour ?? 0):\(String(format: "%02d", parts.minute ?? 0))"
    }
}
