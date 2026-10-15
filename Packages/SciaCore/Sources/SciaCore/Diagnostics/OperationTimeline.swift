public import Foundation

/// 違和感レポートのログから、確保した時刻の直前にユーザーがした操作を古い順に並べる。
public enum OperationTimeline {
    public struct Step: Sendable, Equatable {
        /// 操作のログの時刻。続けて同じ操作をした場合は、最初の操作の時刻。
        public let date: Date
        /// 確保した時刻の何秒前か。続けて同じ操作をした場合は、最初の操作の時刻。
        public let secondsBefore: Int
        public let summary: String
        /// 続けて同じ操作をした回数。
        public let count: Int
        /// ユーザーの操作ではなく、アプリが記録した失敗。
        public let isAppEvent: Bool

        public init(date: Date, secondsBefore: Int, summary: String, count: Int, isAppEvent: Bool) {
            self.date = date
            self.secondsBefore = secondsBefore
            self.summary = summary
            self.count = count
            self.isAppEvent = isAppEvent
        }

        public var line: String {
            let repeated = count > 1 ? "（\(count)回）" : ""
            let prefix = isAppEvent ? "アプリ: " : ""
            return "\(secondsBefore)秒前 \(prefix)\(summary)\(repeated)"
        }
    }

    /// 違和感を覚えるきっかけになった操作は直前にあるはずで、古い操作まで含めると一覧が長くなり読みにくいため、既定では2分前までにする。
    public static let defaultWindow: TimeInterval = 2 * 60

    public static func steps(from logs: [LogLine], capturedAt: Date, window: TimeInterval = defaultWindow) -> [Step] {
        var steps: [Step] = []
        for log in logs where log.date >= capturedAt.addingTimeInterval(-window) && log.date <= capturedAt {
            guard let (summary, isAppEvent, mergesRepeats) = describe(log) else { continue }
            if mergesRepeats, let last = steps.last, last.summary == summary, last.isAppEvent == isAppEvent {
                steps[steps.count - 1] = Step(date: last.date, secondsBefore: last.secondsBefore, summary: summary, count: last.count + 1, isAppEvent: isAppEvent)
            } else {
                let seconds = Int(capturedAt.timeIntervalSince(log.date).rounded())
                steps.append(Step(date: log.date, secondsBefore: seconds, summary: summary, count: 1, isAppEvent: isAppEvent))
            }
        }
        return steps
    }

    /// - Returns: 一覧の文、アプリの失敗か、続けて同じ文になったら1行にまとめるか。
    private static func describe(_ log: LogLine) -> (String, Bool, Bool)? {
        if log.category == UserAction.logCategory, let action = UserAction(logMessage: log.message) {
            // スクロールは、量や時間を丸めた文が同じでも別々の1回で、コメントを付けたい1回を選べるよう、まとめない。
            if case .scroll = action {
                return (action.summary, false, false)
            }
            return (action.summary, false, true)
        }
        // 失敗の本文は利用者に読めない内部の言葉なので、どの領域で起きたかだけを伝える。
        if log.level == "error" || log.level == "fault" {
            return ("\(log.category)で失敗が記録された", true, true)
        }
        return nil
    }
}
