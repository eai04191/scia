import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 自動翻訳の訳文が届いて本文を置き換えるときの見え方。
@Suite(.scratch, .failureState)
@MainActor
struct TranslationArrivalTests {
    private struct ExpandingTranslator: StatusTranslating {
        func translate(_ parts: [TranslationPart], from source: String, to target: String, strategy: TranslationStrategy) async throws -> [TranslationPart] {
            parts.map { part in
                if case .text(let text) = part { .text("訳文" + String(repeating: text, count: 8)) } else { part }
            }
        }
    }

    private func statuses() -> [Status] {
        let account = Account(id: "1", username: "a", acct: "a", displayName: "A", avatar: nil)
        return (0..<40).map { index in
            Status(
                id: String(9_000 - index),
                createdAt: Date(timeIntervalSince1970: 0),
                account: account,
                content: "<p>A post that is long enough to wrap onto the next line of the row.</p>",
                spoilerText: "",
                language: "en",
                url: nil
            )
        }
    }

    /// 高さの変わる投稿が画面の上端にかかっていても、その投稿の画面上の位置は変わらない。
    @Test(arguments: [CGFloat(0), 30])
    func translatedRowKeepsItsPosition(offsetIntoRow: CGFloat) async throws {
        let scope = TaskScope()
        let store = StatusTranslationStore(translator: ExpandingTranslator(), targetLanguage: "ja", strategy: .lowLatency, scope: scope, clock: TestClock(), applyInterval: { .zero })
        store.setLanguages(["en"])
        let harness = try TimelineHarness { $0.translations = store }
        defer { harness.tearDown() }
        let all = statuses()
        harness.setStatuses(all)
        let target = all[20]
        try harness.scroll(to: .status(target.id), at: .top)
        harness.collectionView.contentOffset.y += offsetIntoRow
        harness.collectionView.layoutIfNeeded()
        let before = try #require(harness.windowMinY(of: .status(target.id)))

        store.request([TranslationSource(target)])
        try await waitUntil { store.translation(for: TranslationSource(target)) != nil }
        harness.viewController.applyTranslations([.status(target.id)])

        let after = try #require(harness.windowMinY(of: .status(target.id)))
        #expect(abs(after - before) <= 0.5)
        #expect(harness.secondaryText(of: target.id)?.hasPrefix("訳文") == true)
    }

    /// 囲みの本文の先頭に足す翻訳のマークの空きは、先頭の文字の書体と段落の形だけを引き継ぐ。リンクを引き継ぐと、マークを押して先頭のリンクが開く。
    @Test func translationMarkDoesNotInheritLink() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let font = UIFont.systemFont(ofSize: 15)
        let text = NSAttributedString(string: "example.com/a", attributes: [.font: font, .linkDestination: RichText.LinkDestination.url(url), .copiedLinkText: "https://example.com/a"])

        let reserved = EmbeddedPostView.reservingTranslationMark(in: text, scale: 2)

        #expect(reserved.string.hasSuffix(" example.com/a"))
        #expect(reserved.length == text.length + 2)
        let attributes = reserved.attributes(at: 0, effectiveRange: nil)
        #expect(attributes[.linkDestination] == nil)
        #expect(attributes[.copiedLinkText] == nil)
        #expect(attributes[.font] as? UIFont == font)
        let attachment = try #require(attributes[.attachment] as? NSTextAttachment)
        #expect(attachment.bounds.height == EmojiFont.glyphHeight(of: font) * 2)
        #expect(reserved.attribute(.linkDestination, at: 2, effectiveRange: nil) != nil)
    }

    private func line(_ y: CGFloat, width: CGFloat) -> TextReplacementTransition.Line {
        let rect = CGRect(x: 0, y: y, width: width, height: 20)
        return TextReplacementTransition.Line(rect: rect, words: [rect])
    }

    /// 段落の順に、先頭の行から組にする。時間は行の幅に応じて割り振り、続けてつなぐ。
    @Test func slotsRunInReadingOrderWithoutGaps() {
        let slots = TextReplacementTransition.slots(
            old: [[line(0, width: 100)], [line(30, width: 100)]],
            new: [[line(0, width: 100), line(20, width: 100)], [line(50, width: 200)]],
            duration: 1
        )

        #expect(slots.map(\.unit) == [0, 0, 1])
        #expect(slots[0].old != nil && slots[0].new != nil)
        #expect(slots[1].old == nil && slots[1].new != nil)
        #expect(slots[2].oldTargetY == 50)
        #expect(abs(slots[0].duration - 0.25) < 0.001)
        #expect(abs(slots[2].start - 0.5) < 0.001)
        #expect(abs((slots[2].start + slots[2].duration) - 1) < 0.001)
    }

    /// 段落の数が違えば、全体を1つの単位にして先頭から置き換える。
    @Test func mismatchedUnitsBecomeOneUnit() {
        let slots = TextReplacementTransition.slots(old: [[line(0, width: 100)]], new: [[line(0, width: 100)], [line(30, width: 100)]], duration: 1)

        #expect(Set(slots.map(\.unit)) == [0])
        #expect(slots.count == 2)
    }

    /// 新しい行のない前の行には、順番の時間を割り振らない。
    @Test func extraOldLinesTakeNoTurn() {
        let slots = TextReplacementTransition.slots(old: [[line(0, width: 100), line(20, width: 100)]], new: [[line(0, width: 100)]], duration: 1)

        #expect(slots[1].new == nil)
        #expect(slots[1].duration == 0)
        #expect(abs(slots[0].duration - 1) < 0.001)
    }

    /// 右から左に書く行では、右端の語から動き始める。
    @Test func rightToLeftLineStartsFromRight() {
        let right = CGRect(x: 80, y: 0, width: 20, height: 20)
        let left = CGRect(x: 0, y: 0, width: 20, height: 20)
        let rtl = TextReplacementTransition.Line(rect: CGRect(x: 0, y: 0, width: 100, height: 20), words: [right, left])
        let slot = TextReplacementTransition.Slot(unit: 0, old: rtl, new: nil, oldTargetY: 0, start: 0, duration: 1)

        #expect(TextReplacementTransition.wordStart(right, in: rtl, slot: slot) == 0)
        #expect(TextReplacementTransition.wordStart(left, in: rtl, slot: slot) > 0.5)
    }

    /// 濃さを変える時間は、短い行でも一番長い行に合わせる。短い行だけ速く消えて前の行を追い越さないように。
    @Test func fadeDurationFollowsLongestLine() {
        let slots = TextReplacementTransition.slots(old: [[line(0, width: 300), line(20, width: 30)]], new: [[line(0, width: 300)]], duration: 1)

        #expect(abs(TextReplacementTransition.fadeDuration(slots: slots, fadeWidth: 0.5) - slots[0].duration * 0.5) < 0.001)
    }

    /// 同じ行の語は別の枠に分ける。語に当たらない記号は前の語に含める。
    @Test func wordsSplitWithinLine() throws {
        let text = NSAttributedString(string: "ab, cd")
        var frames: [Int: CGRect] = [:]
        for index in 0..<6 {
            frames[index] = CGRect(x: CGFloat(index) * 10, y: 0, width: 10, height: 20)
        }

        let line = try #require(TextReplacementTransition.units(of: text, frames: frames).first?.first)

        #expect(line.words.count == 2)
        #expect(line.words[0].maxX == 40)
    }

    /// 改行で単位に分け、同じ行の文字は1つの枠にまとめる。
    @Test func unitsGroupCharactersIntoLines() {
        let text = NSAttributedString(string: "ab\ncd")
        let frames: [Int: CGRect] = [
            0: CGRect(x: 0, y: 0, width: 10, height: 20),
            1: CGRect(x: 0, y: 20, width: 10, height: 20),
            3: CGRect(x: 0, y: 40, width: 10, height: 20),
        ]

        #expect(TextReplacementTransition.units(of: text, frames: frames).map(\.count) == [2, 1])
    }
}
