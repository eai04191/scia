import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 高さを測っている間のスタックに、行の種類と部品の名前が残る。クラッシュログから絞り込むために使う。
@Suite(.scratch)
@MainActor
struct SizingTraceTests {
    private final class Target: SizingMeasurable {
        var symbols: [String] = []

        func measureSizing(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
            symbols = Thread.callStackSymbols
            return attributes
        }
    }

    private static func stack(_ trace: SizingTrace) -> String {
        let target = Target()
        _ = trace.run(on: target, UICollectionViewLayoutAttributes())
        return target.symbols.joined(separator: "\n")
    }

    private static func functionName(_ row: TimelineRowKind) -> String {
        switch row {
        case .other: "rowOther"
        default: "row" + row.rawValue.prefix(1).uppercased() + row.rawValue.dropFirst()
        }
    }

    @Test(arguments: TimelineRowKind.allCases) func stackNamesRowKind(row: TimelineRowKind) {
        #expect(Self.stack(SizingTrace(row: row)).contains(Self.functionName(row)))
    }

    @Test func stackNamesOnlyContainedParts() {
        let stack = Self.stack(SizingTrace(row: .status, parts: [.poll, .media]))

        #expect(stack.contains("partPoll"))
        #expect(stack.contains("partMedia"))
        for absent in ["partSpoiler", "partCard", "partEmbed", "partReactions"] {
            #expect(!stack.contains(absent), "\(absent)")
        }
    }

    @Test func returnsMeasuredAttributes() {
        let attributes = UICollectionViewLayoutAttributes()

        #expect(SizingTrace(row: .notification, parts: [.spoiler, .media, .poll, .card, .embed, .reactions]).run(on: Target(), attributes) === attributes)
    }

    @Test func postConfigurationReportsItsParts() {
        let account = Account(id: "1", username: "a", acct: "a", displayName: "名前", avatar: nil)
        let poll = Poll(id: "1", expiresAt: nil, expired: false, multiple: false, votesCount: 0, options: [])
        let status = Status(id: "100", createdAt: Date(timeIntervalSince1970: 1_800_000_000), account: account, content: "<p>本文</p>", spoilerText: "", url: nil, poll: poll)
        let timeline = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: AppSettings.isolated())

        let configuration = timeline.contentConfiguration(for: status, base: .cell())
        let cell = TimelineCell()

        #expect(configuration.sizingParts == [.poll])
        cell.updateSizingParts(from: configuration)
        #expect(cell.sizingTrace.parts == [.poll])
        cell.updateSizingParts(from: nil)
        #expect(cell.sizingTrace.parts == [])
    }
}
