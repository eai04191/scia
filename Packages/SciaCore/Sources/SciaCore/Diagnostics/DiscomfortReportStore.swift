public import Foundation

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
        let url = directory.appending(path: Self.fileName(for: report.capturedAt))
        try Self.encoder.encode(report).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// 保存済みのレポートを、新しい順に返す。
    public func loadAll() throws -> [DiscomfortReport] {
        guard FileManager.default.fileExists(atPath: directory.path()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(DiscomfortReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

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
