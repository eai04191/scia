public import Foundation
import OSLog

/// 実行中のプロセスが出したログのうち、Sciaのsubsystemのものを読む。
public enum RecentLogReader {
    /// `start`から`end`までのログを古い順に返す。
    /// OSLogStoreに残るのはinfo以上のレベルで、debugレベルのログは含まれない。
    public static func read(subsystem: String = SciaLog.subsystem, from start: Date, to end: Date) async throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(date: start),
            matching: NSPredicate(format: "subsystem == %@", subsystem)
        )
        return entries.compactMap { entry -> LogLine? in
            guard let log = entry as? OSLogEntryLog, log.date >= start, log.date <= end else { return nil }
            return LogLine(date: log.date, category: log.category, level: levelName(log.level), message: log.composedMessage)
        }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "undefined"
        @unknown default: "unknown"
        }
    }
}
