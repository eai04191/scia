public import Foundation

/// 投稿の名前の行に、表示名とacctをどう並べるか。
public enum StatusNameStyle: String, CaseIterable, Sendable {
    case nameAndAcct
    case nameOnly
    case acctOnly
    case acctAndName

    /// 並べる順。先頭を目立たせ、2つ目は控えめに描く。
    public var parts: [StatusNamePart] {
        switch self {
        case .nameAndAcct: [.displayName, .acct]
        case .nameOnly: [.displayName]
        case .acctOnly: [.acct]
        case .acctAndName: [.acct, .displayName]
        }
    }
}

public enum StatusNamePart: Sendable {
    case displayName
    case acct
}

/// 投稿の時刻の書き方。
public enum StatusTimeStyle: String, CaseIterable, Sendable {
    /// 「3分」のように、今からどれだけ前か。1週間より前は日付にする。
    case relative
    /// 「10/3 12:34」のような日時。
    case absolute
}

/// アイコンの形。
public enum AvatarShape: String, CaseIterable, Sendable {
    case circle
    case roundedSquare
}

/// リンクカードのサムネイルを、カードのどちらの端に置くか。画面の向きによらず、左右をそのまま指す。
/// 文字はこれによらず、文字の言語の方向に寄せる。
public enum LinkCardThumbnailSide: String, CaseIterable, Sendable {
    case left
    case right
}

/// 一覧の投稿の添付ファイルの並べ方。
public enum MediaArrangement: String, CaseIterable, Sendable {
    /// 本文の下に、行の幅いっぱいで並べる。
    case belowBody
    /// 本文の右に小さな正方形で出し、2つ以上なら重ねる。
    case besideBody
}

/// お気に入りとブーストの光に、何を示すかのアイコンを添えるか。
public enum ReactionGlowIcons: String, CaseIterable, Sendable {
    case none
    /// 下の端に、ブーストとお気に入りのアイコンを1つずつ置く。
    case atBottom
    /// 下の端に、小さなアイコンを大きさと濃さを変えて散らす。
    case scattered
}

/// ライトモードのお気に入りの光の色。ダークモードではいつも黄色にする。
public enum ReactionGlowLightFavouriteColor: String, CaseIterable, Sendable {
    /// 白い背景では黄色が見えにくいため、既定はこちら。
    case orange
    case yellow
}

public enum StatusTimestamp {
    /// 相対表記で、日付に切り替えるまでの日数。
    static let relativeDays = 7

    /// `now`の時点での、`date`の表記。日付と時刻は`calendar`のタイムゾーンと暦で数える。
    /// 日付と時刻の並べ方は、端末の地域と12時間制の設定（`locale`）に従う。日本の地域の24時間制なら「12:34」「10/3 12:34」「2025/10/3 12:34」。
    /// 端末の時計が遅れていて`date`が未来になっても、0秒前として扱う。
    public static func text(
        for date: Date,
        now: Date,
        style: StatusTimeStyle,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        format(date, now: now, style: style, calendar: calendar, locale: locale, month: .defaultDigits)
    }

    /// VoiceOverで読む表記。「10/3」を分数のように読まないよう、月を言葉で書く（「10月3日」）。ほかは`text`と同じ。
    public static func accessibilityText(
        for date: Date,
        now: Date,
        style: StatusTimeStyle,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        format(date, now: now, style: style, calendar: calendar, locale: locale, month: .wide)
    }

    private static func format(
        _ date: Date,
        now: Date,
        style: StatusTimeStyle,
        calendar: Calendar,
        locale: Locale,
        month: Date.FormatStyle.Symbol.Month
    ) -> String {
        let format = DateFormat(now: now, calendar: calendar, locale: locale, month: month)
        return switch style {
        case .relative: relativeText(for: date, now: now, format: format)
        case .absolute: format.dateAndTime(date)
        }
    }

    private static func relativeText(for date: Date, now: Date, format: DateFormat) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        switch seconds {
        case ..<60: return "\(seconds)秒"
        case ..<3_600: return "\(seconds / 60)分"
        case ..<86_400: return "\(seconds / 3_600)時間"
        case ..<(86_400 * relativeDays): return "\(seconds / 86_400)日"
        default: return format.date(date)
        }
    }

    /// 端末の地域の並べ方で書く日付と時刻。今日なら時刻だけ、今年なら年を省く。
    private struct DateFormat {
        let now: Date
        let calendar: Calendar
        let style: Date.FormatStyle
        let month: Date.FormatStyle.Symbol.Month

        init(now: Date, calendar: Calendar, locale: Locale, month: Date.FormatStyle.Symbol.Month) {
            self.now = now
            self.calendar = calendar
            style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            self.month = month
        }

        func date(_ date: Date) -> String {
            date.formatted(dayStyle(for: date))
        }

        func dateAndTime(_ date: Date) -> String {
            guard !calendar.isDate(date, inSameDayAs: now) else { return date.formatted(style.hour().minute()) }
            return date.formatted(dayStyle(for: date).hour().minute())
        }

        private func dayStyle(for date: Date) -> Date.FormatStyle {
            let monthDay = style.month(month).day()
            return calendar.isDate(date, equalTo: now, toGranularity: .year) ? monthDay : monthDay.year()
        }
    }
}
