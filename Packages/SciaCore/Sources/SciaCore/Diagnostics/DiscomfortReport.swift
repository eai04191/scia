public import Foundation

/// 手触りに違和感を覚えた瞬間の状態、直前のログ、ユーザーのメモをまとめたもの。
public struct DiscomfortReport: Codable, Sendable, Equatable {
    /// 状態とログを確保した時刻。メモを書き終えた時刻ではない。
    public let capturedAt: Date
    public var memo: String
    public let stateDumps: [StateDump]
    public let logs: [LogLine]

    public init(capturedAt: Date, memo: String, stateDumps: [StateDump], logs: [LogLine]) {
        self.capturedAt = capturedAt
        self.memo = memo
        self.stateDumps = stateDumps
        self.logs = logs
    }
}

public struct StateDump: Codable, Sendable, Equatable {
    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public struct LogLine: Codable, Sendable, Equatable {
    public let date: Date
    public let category: String
    public let level: String
    public let message: String

    public init(date: Date, category: String, level: String, message: String) {
        self.date = date
        self.category = category
        self.level = level
        self.message = message
    }
}
