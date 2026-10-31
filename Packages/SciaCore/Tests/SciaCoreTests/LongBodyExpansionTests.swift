import Foundation
import Testing
@testable import SciaCore

struct LongBodyExpansionTests {
    private let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))
    private let rule = BodyTruncation(threshold: 32, lines: 15)

    private func status(id: String = "10", spoilerText: String = "", reblog: Status? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account, content: "<p>本文</p>", spoilerText: spoilerText, url: nil, reblog: reblog)
    }

    @Test func cutsOnlyBodiesLongerThanThreshold() throws {
        let rule = try #require(BodyTruncation(threshold: 32, lines: 15))

        #expect(rule.lineLimit(exceedsThreshold: false) == 0)
        #expect(rule.lineLimit(exceedsThreshold: true) == 15)
    }

    @Test func zeroThresholdNeverCuts() {
        #expect(BodyTruncation(threshold: 0, lines: 15) == nil)
    }

    @Test func showsAtMostThresholdLines() throws {
        let rule = try #require(BodyTruncation(threshold: 10, lines: 20))

        #expect(rule.visibleLines == 10)
    }

    @Test func showsAtLeastOneLine() throws {
        let rule = try #require(BodyTruncation(threshold: 10, lines: 0))

        #expect(rule.visibleLines == 1)
    }

    @Test func cutsPlainStatus() {
        #expect(LongBodyExpansion().truncation(forBodyOf: status(), isThreadFocus: false, rule: rule) == rule)
    }

    @Test func keepsThreadFocusWhole() {
        #expect(LongBodyExpansion().truncation(forBodyOf: status(), isThreadFocus: true, rule: rule) == nil)
        #expect(LongBodyExpansion().truncation(forXPost: "1", isThreadFocus: true, rule: rule) == nil)
    }

    @Test func keepsStatusWithSpoilerWhole() {
        #expect(LongBodyExpansion().truncation(forBodyOf: status(spoilerText: "ネタバレ"), isThreadFocus: false, rule: rule) == nil)
    }

    @Test func expandedStatusStaysWholeInBoosts() {
        var expansion = LongBodyExpansion()
        let original = status()
        let boost = status(id: "11", reblog: original)

        expansion.expand(.status(original.id))

        #expect(expansion.truncation(forBodyOf: original, isThreadFocus: false, rule: rule) == nil)
        #expect(expansion.truncation(forBodyOf: boost, isThreadFocus: false, rule: rule) == nil)
        #expect(expansion.truncation(forBodyOf: status(id: "12"), isThreadFocus: false, rule: rule) == rule)
    }

    @Test func expandsXPostsSeparatelyFromStatuses() {
        var expansion = LongBodyExpansion()

        expansion.expand(.xPost("10"))

        #expect(expansion.truncation(forXPost: "10", isThreadFocus: false, rule: rule) == nil)
        #expect(expansion.truncation(forBodyOf: status(id: "10"), isThreadFocus: false, rule: rule) == rule)
    }

    @Test func passesNoRuleThrough() {
        #expect(LongBodyExpansion().truncation(forBodyOf: status(), isThreadFocus: false, rule: nil) == nil)
    }
}
