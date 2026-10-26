public import Foundation
import os

/// 違和感レポートをJSONファイルとして保存する。
public struct DiscomfortReportStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `capturedAt`の時刻を名前にしたファイルへ保存し、そのURLを返す。
    @discardableResult
    public func save(_ report: DiscomfortReport) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(fileName: SafeFileName(Self.fileName(for: report.capturedAt)))
        // 書いている途中で落ちても、書きかけのファイルをレポートとして残さないよう、読む対象にならない名前に書き終えてから移す。
        // 移す先がすでにあれば移さずに失敗する（`moveItem`は上書きしない）。同じ時刻のレポートを消さないため。
        let partial = directory.appending(path: ".partial-\(UUID().uuidString)")
        do {
            try Self.encoder.encode(report).write(to: partial)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return url
    }

    /// 保存済みのレポートを、新しい順に返す。読めないファイルは、記録して飛ばす。1件のために残りを読めなくしないため。
    public func loadAll() throws -> [DiscomfortReport] {
        guard FileManager.default.fileExists(atPath: directory.path()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                do {
                    return try decoder.decode(DiscomfortReport.self, from: Data(contentsOf: url))
                } catch {
                    Self.logger.error("discomfort report unreadable, skipped: \(SciaLog.describe(error), privacy: .public)")
                    return nil
                }
            }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 保存したレポートを全部消す。設定のストレージの画面で、使う人が消すときに呼ぶ。次に保存するときは、フォルダーを作り直す。
    public func removeAll() throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private static let logger = SciaLog.logger(category: "discomfort")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        return encoder
    }()

    private static func fileName(for date: Date) -> String {
        let stamp = date.formatted(
            Date.ISO8601FormatStyle(timeZone: .current)
                .year().month().day().dateSeparator(.omitted)
                .time(includingFractionalSeconds: true).timeSeparator(.omitted)
                .timeZone(separator: .omitted)
        )
        return "discomfort-\(stamp).json"
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static let iso8601WithFractionalSeconds = custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let container = try decoder.singleValueContainer()
        return try Date(container.decode(String.self), strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
