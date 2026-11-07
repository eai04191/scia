import Foundation
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投票の形を入れ替えるときの動き。決まりはdocs/poll.mdの「動き」にある。
@MainActor
struct PollViewTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let barDuration: TimeInterval = 0.5
    private static let modeChangeDuration: TimeInterval = 0.3

    private static func poll(id: String = "p1", votes: [Int] = [3, 1], voted: Bool = false, ownVotes: [Int] = []) -> Poll {
        Poll(
            id: id,
            expiresAt: now.addingTimeInterval(86_400),
            expired: false,
            multiple: false,
            votesCount: votes.reduce(0, +),
            options: votes.enumerated().map { Poll.Option(title: "選択肢\($0.offset)", votesCount: $0.element) },
            voted: voted,
            ownVotes: ownVotes
        )
    }

    private static func content(_ poll: Poll, choices: PollChoices = PollChoices(), modeChangeDuration: TimeInterval = modeChangeDuration) -> PollView.Content {
        let font = UIFont.preferredFont(forTextStyle: .body)
        return PollView.Content(
            pollID: poll.id,
            display: PollDisplay(poll: poll, choices: choices, now: now),
            titles: poll.options.map { NSAttributedString(string: $0.title) },
            titleFont: font,
            footerFont: .preferredFont(forTextStyle: .footnote),
            footerSpacing: 8,
            optionSpacing: 6,
            optionPadding: 8,
            barDuration: barDuration,
            modeChangeDuration: modeChangeDuration
        )
    }

    private static func revealed(_ poll: Poll) -> PollChoices {
        var choices = PollChoices()
        choices.reveal(poll.id)
        return choices
    }

    /// 窓に置いた投票。窓の層の時間を止めて、テストが進める。
    private static func pollInWindow(_ content: PollView.Content) throws -> (view: PollView, window: UIWindow, clock: LayerClock) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let clock = LayerClock(freezing: window.layer)
        let view = PollView(frame: CGRect(x: 20, y: 100, width: 330, height: 300))
        window.addSubview(view)
        window.isHidden = false
        view.apply(content)
        view.layoutIfNeeded()
        CATransaction.flush()
        return (view, window, clock)
    }

    private static func height(of view: PollView) -> CGFloat {
        view.systemLayoutSizeFitting(CGSize(width: 330, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }

    /// 結果を見ると、投票全体を重ねて切り替えず、要素ごとに動かす。替える前のボタンは複製を消し終えてから新しいボタンを出し、
    /// 割合は0%から数字を入れ替え、先頭の記号は消える動きの間も隠さない。動き終えると、ボタンも割合もふつうに見える。
    @Test func revealingResultsMovesEachElement() async throws {
        let poll = Self.poll()
        let (view, window, clock) = try Self.pollInWindow(Self.content(poll))
        defer { window.isHidden = true }

        view.apply(Self.content(poll, choices: Self.revealed(poll)))
        view.layoutIfNeeded()

        #expect(view.layer.animation(forKey: "modeChange") == nil, "投票全体を重ねて切り替えました")
        #expect(view.leavingButtonCount == 2, "「結果を見る」と「投票」の複製を残していません")
        #expect(view.footerButtons.secondary.alpha == 0, "新しいボタンを、替える前のボタンと重ねて出しました")
        let first = try #require(view.optionRows.first)
        #expect(first.showsIndicator, "先頭の記号を、消える動きの前に隠しました")
        #expect(first.percentTextView.text == "75%")
        #expect(first.percentTextView.alpha == 0)

        try await clock.runUntilIdle()

        #expect(first.percentTextView.lastTransition == Self.barDuration, "割合の数字を入れ替えていません")
        #expect(view.leavingButtonCount == 0)
        #expect(view.footerButtons.secondary.alpha == 1)
        #expect(first.percentTextView.alpha == 1)
        #expect(first.showsBar)
    }

    /// 浮かび上がる前の透明なボタンも押せる。結果を見た直後に「投票に戻る」を押しても効くようにするため。
    @Test func incomingButtonReceivesTouchesWhileTransparent() throws {
        let poll = Self.poll()
        let (view, window, _) = try Self.pollInWindow(Self.content(poll))
        defer { window.isHidden = true }

        view.apply(Self.content(poll, choices: Self.revealed(poll)))
        view.layoutIfNeeded()

        let button = view.footerButtons.secondary
        #expect(button.alpha == 0)
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: view)
        #expect(view.hitTest(center, with: nil) === button, "浮かび上がる前の「投票に戻る」に触れたものを渡していません")
    }

    /// 投票に戻ると、棒を縮めて割合を消し終えてから、先頭の記号を出したままにする。
    @Test func returningToVotingShrinksBarsAndHidesPercent() async throws {
        let poll = Self.poll()
        let (view, window, clock) = try Self.pollInWindow(Self.content(poll, choices: Self.revealed(poll)))
        defer { window.isHidden = true }
        let first = try #require(view.optionRows.first)
        #expect(first.showsBar)

        view.apply(Self.content(poll))
        view.layoutIfNeeded()

        #expect(first.showsBar, "棒を縮める前に隠しました")
        #expect(!first.percentTextView.isHidden, "割合を消す前に隠しました")
        #expect(view.leavingButtonCount == 1, "「投票に戻る」の複製を残していません")

        try await clock.runUntilIdle()

        #expect(!first.showsBar)
        #expect(first.percentTextView.isHidden)
        #expect(first.showsIndicator)
        #expect(view.leavingButtonCount == 0)
        #expect(view.footerButtons.secondary.alpha == 1)
        #expect(view.footerButtons.vote.alpha == 1)
    }

    /// 結果を見る途中で投票に戻っても、投票する形で止まる。複製のボタンも、消している途中の割合も残さない。
    @Test func returningWhileRevealingEndsInVotingForm() async throws {
        let poll = Self.poll()
        let (view, window, clock) = try Self.pollInWindow(Self.content(poll))
        defer { window.isHidden = true }

        view.apply(Self.content(poll, choices: Self.revealed(poll)))
        view.layoutIfNeeded()
        try await clock.advance(by: Self.modeChangeDuration / 2)
        view.apply(Self.content(poll))
        view.layoutIfNeeded()
        try await clock.runUntilIdle()

        for option in view.optionRows {
            #expect(!option.showsBar)
            #expect(option.percentTextView.isHidden)
            #expect(option.showsIndicator)
        }
        #expect(view.leavingButtonCount == 0)
        #expect(view.footerButtons.secondary.alpha == 1)
        #expect(view.footerButtons.vote.alpha == 1)
    }

    /// 使い回した行で別の投票に替わったときは動かさない。ボタンの複製を作らず、割合も数字を入れ替えずに出す。
    @Test func reusedRowForOtherPollDoesNotAnimate() throws {
        let (view, window, _) = try Self.pollInWindow(Self.content(Self.poll(id: "a")))
        defer { window.isHidden = true }

        let other = Self.poll(id: "b", voted: true, ownVotes: [0])
        view.apply(Self.content(other))
        view.layoutIfNeeded()

        #expect(view.leavingButtonCount == 0)
        #expect(view.footerButtons.secondary.alpha == 1)
        let first = try #require(view.optionRows.first)
        #expect(!first.showsIndicator)
        #expect(first.percentTextView.alpha == 1)
        #expect(first.percentTextView.lastTransition == nil)
        #expect(view.summaryTextView.lastTransition == nil)
    }

    /// 同じ投票で人数が変わったら、下の行の数字を入れ替える。別の投票に替わったときは入れ替えない。
    @Test func summaryNumbersChangeOnlyForSamePoll() async throws {
        let (view, window, clock) = try Self.pollInWindow(Self.content(Self.poll(votes: [3, 1])))
        defer { window.isHidden = true }

        view.apply(Self.content(Self.poll(votes: [4, 1])))
        view.layoutIfNeeded()
        try await clock.runUntilIdle()
        #expect(view.summaryTextView.text == "5票・残り1日")
        #expect(view.summaryTextView.lastTransition == Self.barDuration)

        view.apply(Self.content(Self.poll(id: "other", votes: [6, 1])))
        #expect(view.summaryTextView.text == "7票・残り1日")
        #expect(view.summaryTextView.lastTransition == nil)
    }

    /// 棒が伸びている途中で投票に戻しても、取り消した伸びる動きの終わりで棒を隠さず、今の長さから縮める。
    @Test func returningWhileBarsGrowShrinksFromCurrentLength() async throws {
        let poll = Self.poll()
        let (view, window, clock) = try Self.pollInWindow(Self.content(poll))
        defer { window.isHidden = true }
        let first = try #require(view.optionRows.first)

        view.apply(Self.content(poll, choices: Self.revealed(poll)))
        view.layoutIfNeeded()
        try await clock.advance(by: Self.barDuration / 3)
        view.apply(Self.content(poll))
        view.layoutIfNeeded()
        try await clock.advance(by: LayerClock.frame * 2)

        #expect(first.showsBar, "縮める前に棒を隠しました")
        try await clock.runUntilIdle()
        #expect(!first.showsBar)
    }

    /// 動きを始める前に形を続けて替えても、替える前のボタンの複製を残さない。
    @Test func consecutiveModeChangesBeforeStartLeaveNoButtonCopies() async throws {
        let poll = Self.poll()
        let (view, window, clock) = try Self.pollInWindow(Self.content(poll))
        defer { window.isHidden = true }

        view.apply(Self.content(poll, choices: Self.revealed(poll)))
        view.apply(Self.content(poll))
        view.layoutIfNeeded()
        try await clock.runUntilIdle()

        #expect(view.leavingButtonCount == 0, "替える前のボタンの複製が残っています")
    }

    /// 形を入れ替える時間を0にして投票に戻ったときも、消える動きにかけた先頭の記号を元に戻す。
    @Test func returningWithoutModeChangeMotionRestoresIndicator() async throws {
        let poll = Self.poll()
        let (view, window, clock) = try Self.pollInWindow(Self.content(poll))
        defer { window.isHidden = true }
        let first = try #require(view.optionRows.first)

        view.apply(Self.content(poll, choices: Self.revealed(poll)))
        view.layoutIfNeeded()
        try await clock.runUntilIdle()
        #expect(first.indicatorIsDisappeared)

        view.apply(Self.content(poll, modeChangeDuration: 0))
        view.layoutIfNeeded()
        try await clock.runUntilIdle()
        #expect(first.showsIndicator)
        #expect(!first.indicatorIsDisappeared, "先頭の記号が、消える動きにかけたままです")
    }

    /// 形を入れ替えても、投票の高さは変えない。読んでいる位置を動かさないため。
    @Test func modeChangeKeepsHeight() throws {
        let poll = Self.poll()
        let (view, window, _) = try Self.pollInWindow(Self.content(poll))
        defer { window.isHidden = true }
        let voting = Self.height(of: view)

        view.apply(Self.content(poll, choices: Self.revealed(poll)))
        #expect(Self.height(of: view) == voting)
    }
}
