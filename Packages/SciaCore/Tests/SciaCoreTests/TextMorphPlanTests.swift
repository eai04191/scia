import CoreGraphics
import Testing
@testable import SciaCore

struct TextMorphPlanTests {
    /// 1文字10ptで並べた行。
    private func line(_ range: Range<Int>, x: CGFloat, y: CGFloat, content: TextMorphContent = .body) -> TextMorphScene.Line {
        TextMorphScene.Line(content: content, range: range, origin: CGPoint(x: x, y: y), boundaries: (0 ... range.count).map { CGFloat($0) * 10 }, ascent: 14, descent: 4)
    }

    private let fade = TextMorphFade(top: 8, left: 8, bottom: 8, right: 20)

    /// カプセルは幅100ptで、行末を20ptで薄くする。
    private func capsule(_ lines: [TextMorphScene.Line]) -> TextMorphScene {
        TextMorphScene(lines: lines, window: CGRect(x: 20, y: 10, width: 100, height: 30), fade: fade)
    }

    /// 入力欄は幅100ptで、行の高さは22pt。
    private func field(_ lines: [TextMorphScene.Line], top: CGFloat = 40, height: CGFloat = 100) -> TextMorphScene {
        TextMorphScene(lines: lines, window: CGRect(x: 20, y: top, width: 100, height: height), fade: fade)
    }

    /// カプセルに見えている1行目は動かし、カプセルの行末より先の2行目は入力欄で浮かび上がらせる。
    @Test func movesTheVisibleLineAndRaisesTheRest() {
        let a = capsule([line(0 ..< 20, x: 28, y: 30)])
        let b = field([line(0 ..< 10, x: 28, y: 60), line(10 ..< 20, x: 28, y: 82)])
        let plan = TextMorphPlan(a: a, b: b)
        #expect(plan.flights == [.init(key: .init(content: .body, range: 0 ..< 10), originInA: CGPoint(x: 28, y: 30), originInB: CGPoint(x: 28, y: 60))])
        #expect(plan.stays == [.init(key: .init(content: .body, range: 10 ..< 20), originInB: CGPoint(x: 28, y: 82))])
    }

    /// 返信の宛先はカプセルにないので、入力欄の位置で浮かび上がらせ、続く本文はカプセルから動かす。
    @Test func raisesTheMentionAndMovesTheBodyAfterIt() {
        let a = capsule([line(5 ..< 9, x: 48, y: 30)])
        let b = field([line(0 ..< 9, x: 28, y: 60)])
        let plan = TextMorphPlan(a: a, b: b)
        #expect(plan.flights == [.init(key: .init(content: .body, range: 5 ..< 9), originInA: CGPoint(x: 48, y: 30), originInB: CGPoint(x: 78, y: 60))])
        #expect(plan.stays == [.init(key: .init(content: .body, range: 0 ..< 5), originInB: CGPoint(x: 28, y: 60))])
    }

    /// 行末のぼかしにかかる文字しかなければ、カプセルではっきり見えていないものとして、動かさない。
    /// 動かすと、カプセルの行末から入力欄の次の行の頭へ動き、前の行を横切るため。
    @Test func charactersInTheFadeAreNotMoved() {
        // 見える範囲は120ptまでで、100ptより先はぼかしている。7文字目（98〜108pt）は、ぼかしにかかる。
        let a = capsule([line(0 ..< 10, x: 28, y: 30)])
        let b = field([line(0 ..< 7, x: 28, y: 60), line(7 ..< 10, x: 28, y: 82)])
        let plan = TextMorphPlan(a: a, b: b)
        #expect(plan.flights.map(\.key.range) == [0 ..< 7])
        #expect(plan.stays.map(\.key.range) == [7 ..< 10])
        // ぼかしの中で見えている7、8、9文字目は、行末として1行目と一緒に動かしながら薄くする。
        #expect(plan.tails == [.init(key: .init(content: .body, range: 7 ..< 10), originInA: CGPoint(x: 98, y: 30), follows: .init(content: .body, range: 0 ..< 7))])
        #expect(plan.concealedInA.map(\.range) == [0 ..< 7, 7 ..< 10])
    }

    /// 行末と同じ文字は、入力欄の行の中で別のかたまりに分ける。
    @Test func splitsTheLineWhereTheTailReappears() {
        let a = capsule([line(0 ..< 10, x: 28, y: 30)])
        let b = field([line(0 ..< 7, x: 28, y: 60), line(7 ..< 14, x: 28, y: 82)])
        let plan = TextMorphPlan(a: a, b: b)
        #expect(plan.tails.map(\.key.range) == [7 ..< 10])
        #expect(plan.stays.map(\.key.range) == [7 ..< 10, 10 ..< 14])
        #expect(plan.stays.map(\.originInB) == [CGPoint(x: 28, y: 82), CGPoint(x: 58, y: 82)])
    }

    /// 入力欄をスクロールしていて、カプセルに見える文字の行が入力欄の見える範囲の外にあっても、動かす。見える範囲の端で薄くなって消える。
    /// 入力欄の見える範囲の外の行は、浮かび上がらせない。
    @Test func movesIntoScrolledOutLinesAndSkipsHiddenOnes() {
        let a = capsule([line(0 ..< 30, x: 28, y: 30)])
        let b = field([line(0 ..< 10, x: 28, y: -20), line(10 ..< 20, x: 28, y: 2), line(20 ..< 30, x: 28, y: 60)])
        let plan = TextMorphPlan(a: a, b: b)
        #expect(plan.flights.map(\.key.range) == [0 ..< 10])
        #expect(plan.stays.map(\.key.range) == [20 ..< 30])
    }

    /// 両方に「いまどうしてる？」があれば、本文と同じく動かす。
    @Test func movesThePlaceholderWhenBothShowIt() {
        let a = capsule([line(0 ..< 8, x: 28, y: 30, content: .placeholder)])
        let b = field([line(0 ..< 8, x: 28, y: 60, content: .placeholder)])
        let plan = TextMorphPlan(a: a, b: b)
        #expect(plan.flights.map(\.key) == [.init(content: .placeholder, range: 0 ..< 8)])
        #expect(plan.stays.isEmpty)
    }

    /// 宛先だけの返信では、カプセルの「いまどうしてる？」と入力欄の宛先に重なる文字がないので、宛先を浮かび上がらせるだけにする。
    @Test func mentionOnlyReplyRaisesTheMention() {
        let a = capsule([line(0 ..< 8, x: 48, y: 30, content: .placeholder)])
        let b = field([line(0 ..< 5, x: 28, y: 60)])
        let plan = TextMorphPlan(a: a, b: b)
        #expect(plan.flights.isEmpty)
        #expect(plan.stays.map(\.key) == [.init(content: .body, range: 0 ..< 5)])
        // カプセルの「いまどうしてる？」は、宛先と同じ場所に出入りするので、先に消し切るかたまりにする。
        #expect(plan.departures == [.init(key: .init(content: .placeholder, range: 0 ..< 8), originInA: CGPoint(x: 48, y: 30))])
    }
}
