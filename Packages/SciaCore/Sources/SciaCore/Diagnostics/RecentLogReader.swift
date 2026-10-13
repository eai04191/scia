public import Foundation
import OSLog

/// 実行中のプロセスが出したログのうち、Sciaのsubsystemのものを読む。
/// OSLogStoreに残るのはinfo以上のレベルで、debugレベルのログは含まれない。
public enum RecentLogReader {
    public enum ReadError: Error, Equatable, LocalizedError {
        case markerNotFound

        public var errorDescription: String? {
            "確保した時点までのログが、時間内に読めるようになりませんでした"
        }
    }

    /// 読み込みの終わりの目印になるログを書き出し、その本文を返す。
    public static func writeMarker(subsystem: String = SciaLog.subsystem) -> String {
        let marker = "log marker \(UUID().uuidString)"
        Logger(subsystem: subsystem, category: "diagnostics").notice("\(marker, privacy: .public)")
        return marker
    }

    /// `start`から`marker`までのログを古い順に返す。
    /// ログは書いてからOSLogStoreで読めるまでに遅れがある（iOS 27のシミュレーターで約1.5秒）。
    /// `marker`が読めるまで待つことで、マーカーを書いた時点までのログを漏らさず含める。
    /// macOSではOSLogStoreの1回の読み込みに数秒かかることがあり、待ち時間の上限は余裕を持たせている。
    public static func read(
        subsystem: String = SciaLog.subsystem,
        from start: Date,
        untilMarker marker: String,
        timeout: Duration = .seconds(30)
    ) async throws -> [LogLine] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let lines = try read(subsystem: subsystem, from: start, to: Date())
            if let end = lines.firstIndex(where: { $0.message == marker }) {
                return Array(lines[...end])
            }
            guard clock.now < deadline else { throw ReadError.markerNotFound }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func read(subsystem: String, from start: Date, to end: Date) throws -> [LogLine] {
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
