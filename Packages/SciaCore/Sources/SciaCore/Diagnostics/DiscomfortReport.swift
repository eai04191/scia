public import Foundation

/// 手触りに違和感を覚えた瞬間の状態、直前のログ、ユーザーのメモをまとめたもの。
public struct DiscomfortReport: Codable, Sendable, Equatable {
    /// 状態とログを確保した時刻。メモを書き終えた時刻ではない。
    public let capturedAt: Date
    public var memo: String
    /// 直前の操作の一覧のうち、特定の操作に付けたコメント。全体のことは`memo`に書く。
    public var operationComments: [OperationComment]
    public let stateDumps: [StateDump]
    public let logs: [LogLine]

    public init(capturedAt: Date, memo: String, operationComments: [OperationComment], stateDumps: [StateDump], logs: [LogLine]) {
        self.capturedAt = capturedAt
        self.memo = memo
        self.operationComments = operationComments
        self.stateDumps = stateDumps
        self.logs = logs
    }
}

public struct OperationComment: Codable, Sendable, Equatable {
    /// コメントを付けた操作のログの時刻。`logs`と突き合わせる手がかりにする。
    public let date: Date
    /// コメントを付けたときに一覧に出ていた操作の説明。
    public let operation: String
    public let text: String

    public init(date: Date, operation: String, text: String) {
        self.date = date
        self.operation = operation
        self.text = text
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
