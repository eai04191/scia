import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// ステータスバーの通知の、出入りと入れ替えの見え方。
@MainActor
struct StatusBarTickerViewTests {
    private let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)

    private func item(_ id: String) -> StatusBarTickerItem {
        StatusBarTickerItem(id: id, kind: .favourite, account: account, subject: .text(RichText.plain("本文\(id)", emojis: [])))
    }

    /// 縮めている途中に次の通知が来たら、残っている中身を見えている濃さから薄くして入れ替える。その場で取り除くと、中身が1コマで消える。
    @Test func arrivalWhileShrinkingFadesOutRemainingContent() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        let clock = LayerClock(freezing: window.layer)
        let view = StatusBarTickerView(cutout: .island(CGRect(x: 140, y: 11, width: 110, height: 32), sideMargin: 14))
        view.mediaTime = { clock.now }
        view.animationDuration = 1
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 54)
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        let capsule = try #require(view.subviews.first { $0.isAccessibilityElement })

        view.show(item("1"), animated: true)
        try await clock.runUntilIdle()
        let first = capsule.subviews
        view.hide(animated: true)
        try await clock.advance(by: 0.3)
        let before = try #require(first.first?.layer.presentation()).opacity
        #expect(before > 0.5)

        view.show(item("2"), animated: true)
        CATransaction.flush()

        for part in first {
            #expect(part.superview === capsule)
            #expect(abs(try #require(part.layer.presentation()).opacity - before) < 0.01)
        }
        try await clock.advance(by: 0.3)
        #expect(try #require(first.first?.layer.presentation()).opacity < before)
        // 広げ直す途中、残っている中身と新しい中身は、同じ時刻表で背景の左端に沿う。
        let incoming = try #require(capsule.subviews.last { !first.contains($0) && $0.frame.minX < capsule.bounds.midX })
        let outgoingX = try #require(first.first?.layer.presentation()).frame.minX
        #expect(abs(try #require(incoming.layer.presentation()).frame.minX - outgoingX) < 0.5)
        try await clock.runUntilIdle()
        #expect(first.allSatisfy { $0.superview == nil })
        #expect(view.isExpanded)
    }
}

extension StatusBarTickerViewTests {
    /// 縮め始めてから描くまでにメインスレッドが止まっても（押して通知タブへ移るときなど）、止まっていた分だけ進んだところから描かず、広げた形から縮め始める。
    /// あとから加わる中身も、背景と同じ時刻表で端に沿わせる。
    @Test func shrinkStartsWhenFirstDrawnAfterStall() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        let clock = LayerClock(freezing: window.layer)
        let view = StatusBarTickerView(cutout: .island(CGRect(x: 140, y: 11, width: 110, height: 32), sideMargin: 14))
        view.mediaTime = { clock.now }
        view.animationDuration = 1
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 54)
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        let capsule = try #require(view.subviews.first { $0.isAccessibilityElement })
        view.show(item("1"), animated: true)
        try await clock.runUntilIdle()
        let expanded = capsule.frame

        view.hide(animated: true)
        // 描く前に0.3秒止まった。
        window.layer.timeOffset += 0.3
        CATransaction.flush()

        let drawn = try #require(capsule.layer.presentation()).frame
        #expect(abs(drawn.width - expanded.width) < 1)
        try await clock.advance(by: 0.1)
        #expect(try #require(capsule.layer.presentation()).frame.width < expanded.width - 1)
    }
}

/// ステータスバーの通知を消してから、ステータスバーを出し直すまで。
/// ステータスバーを出し直している途中に隠し直すと、システムは1コマで濃く出してから薄くするため、出し直すのは縮め終えてからにし、出し直している間は次を出さない。
@MainActor
@Suite(.serialized)
struct StatusBarTickerStatusBarTests {
    private let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)

    private func item(_ id: String) -> StatusBarTickerItem {
        StatusBarTickerItem(id: id, kind: .favourite, account: account, subject: .text(RichText.plain("本文\(id)", emojis: [])))
    }

    private func makeTicker(clock: TestClock, animationDuration: Double) throws -> StatusBarTicker {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(animationDuration, for: TuningCatalog.statusBarTickerAnimationDuration)
        let ticker = StatusBarTicker(tuning: tuning, clock: clock)
        ticker.scene = { scene }
        return ticker
    }

    /// 縮めている途中に次が届いたら、ステータスバーは隠したまま広げ直す。
    @Test func arrivalWhileShrinkingKeepsStatusBarHidden() async throws {
        let clock = TestClock()
        let ticker = try makeTicker(clock: clock, animationDuration: 1.5)
        defer { ticker.clear() }
        ticker.receive(item("1"))
        let view = try #require(ticker.tickerView)
        try await waitUntil { clock.sleeperCount > 0 }

        clock.advance(by: .seconds(60))
        try await waitUntil { !view.isExpanded }
        #expect(ticker.isHidingStatusBar)

        ticker.receive(item("2"))
        #expect(view.isExpanded)
        #expect(ticker.isHidingStatusBar)
    }

    /// 縮め終えてステータスバーを出し直している間に届いたら、出し終えてから出す。
    @Test func arrivalWhileStatusBarReturnsWaitsForIt() async throws {
        let clock = TestClock()
        let ticker = try makeTicker(clock: clock, animationDuration: 0.05)
        defer { ticker.clear() }
        ticker.receive(item("1"))
        let view = try #require(ticker.tickerView)
        try await waitUntil { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(60))
        // 縮め終えたら、ステータスバーを出し直し、出し終えるまでを待つ。
        try await waitUntil { !ticker.isHidingStatusBar && clock.sleeperCount > 0 }

        ticker.receive(item("2"))
        #expect(!view.isExpanded)

        clock.advance(by: .seconds(0.05))
        try await waitUntil { view.isExpanded }
        #expect(ticker.isHidingStatusBar)
    }

    /// ステータスバーを出し直している間に届いた通知は、出し終えるまでに流せなくなったら（ビューアを開いたときなど）捨て、重ねたウィンドウも隠す。
    @Test func arrivalWhileStatusBarReturnsIsDroppedWhenHidden() async throws {
        let clock = TestClock()
        let ticker = try makeTicker(clock: clock, animationDuration: 0.05)
        defer { ticker.clear() }
        var canShow = true
        ticker.canShow = { canShow }
        ticker.receive(item("1"))
        let view = try #require(ticker.tickerView)
        try await waitUntil { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(60))
        try await waitUntil { !ticker.isHidingStatusBar && clock.sleeperCount > 0 }
        ticker.receive(item("2"))

        canShow = false
        clock.advance(by: .seconds(0.05))

        let window = try #require(view.window)
        try await waitUntil { window.isHidden }
        #expect(!view.isExpanded)
    }
}
