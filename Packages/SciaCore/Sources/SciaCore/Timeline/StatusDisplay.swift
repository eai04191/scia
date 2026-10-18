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

public enum StatusTimestamp {
    /// 相対表記で、日付に切り替えるまでの日数。
    static let relativeDays = 7

    /// `now`の時点での、`date`の表記。日付と時刻は`calendar`のタイムゾーンで数える。
    /// 端末の時計が遅れていて`date`が未来になっても、0秒前として扱う。
    public static func text(for date: Date, now: Date, style: StatusTimeStyle, calendar: Calendar = .current) -> String {
        switch style {
        case .relative: relativeText(for: date, now: now, calendar: calendar)
        case .absolute: absoluteText(for: date, now: now, calendar: calendar)
        }
    }

    private static func relativeText(for date: Date, now: Date, calendar: Calendar) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        switch seconds {
        case ..<60: return "\(seconds)秒"
        case ..<3_600: return "\(seconds / 60)分"
        case ..<86_400: return "\(seconds / 3_600)時間"
        case ..<(86_400 * relativeDays): return "\(seconds / 86_400)日"
        default: return dateText(for: date, now: now, calendar: calendar)
        }
    }

    private static func absoluteText(for date: Date, now: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%d:%02d", components.hour ?? 0, components.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        return "\(dateText(for: date, now: now, calendar: calendar)) \(time)"
    }

    /// 今年なら年を省く。
    private static func dateText(for date: Date, now: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let monthDay = "\(components.month ?? 0)/\(components.day ?? 0)"
        guard components.year != calendar.component(.year, from: now) else { return monthDay }
        return "\(components.year ?? 0)/\(monthDay)"
    }
}
