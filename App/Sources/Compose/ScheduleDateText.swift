import Foundation

/// 予約の日時の表記。投稿欄の予約の行、予約できたときのチップ、予約の一覧で同じ書き方にする。
enum ScheduleDateText {
    /// 「10月28日(火) 9:00」のように、月日、曜日、時刻を書く。今年でなければ年も書く。
    static func title(for date: Date, now: Date, calendar: Calendar) -> String {
        date.formatted(style(for: date, now: now, calendar: calendar).weekday(.abbreviated))
    }

    /// 「10月28日 9:00」のように、曜日を省いて短く書く。チップのように、文の中に入れるときに使う。
    static func shortTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        date.formatted(style(for: date, now: now, calendar: calendar))
    }

    /// 読み上げ。曜日を略さずに読む。
    static func spokenTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        date.formatted(style(for: date, now: now, calendar: calendar).weekday(.wide))
    }

    private static func style(for date: Date, now: Date, calendar: Calendar) -> Date.FormatStyle {
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide).day().hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return style
    }
}
