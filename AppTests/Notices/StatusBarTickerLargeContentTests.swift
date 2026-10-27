import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 大きい文字の設定で、ステータスバーの通知を長押しの拡大表示で読んでいる間は、次の通知へ進めず、消さない。
/// 読んでいる途中で消えると、指を離しても押したことにならず、通知タブを開けない。
@MainActor
@Suite(.serialized)
struct StatusBarTickerLargeContentTests {
    private func tickerView(in scene: UIWindowScene) -> StatusBarTickerView? {
        func find(_ view: UIView) -> StatusBarTickerView? {
            (view as? StatusBarTickerView) ?? view.subviews.lazy.compactMap(find).first
        }
        return scene.windows.lazy.compactMap(find).first
    }

    @Test func holdsWhileTheLargeContentViewerIsShown() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let clock = TestClock()
        let ticker = StatusBarTicker(tuning: TuningStore(defaults: nil), clock: clock)
        ticker.scene = { scene }
        defer { ticker.clear() }
        var tapped = 0
        ticker.onTap = { tapped += 1 }
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)
        ticker.receive(StatusBarTickerItem(id: "1", kind: .favourite, account: account, subject: .text(RichText.plain("本文", emojis: []))))
        let view = try #require(tickerView(in: scene))
        view.layoutIfNeeded()
        // 押した場所は、見えているカプセルの枠で当てる。広がりきる前に押すと、描画が確定しているかどうかで、
        // 広がり始めの小さい枠か、広がった枠かが変わるため、層の時計で広がりきるまで進めてから押す。
        let layerClock = LayerClock(freezing: try #require(view.window).layer)
        try await layerClock.runUntilIdle()
        let capsule = try #require(view.subviews.first { $0.isAccessibilityElement })
        let point = CGPoint(x: capsule.frame.midX, y: capsule.frame.midY)
        let interaction = UILargeContentViewerInteraction(delegate: view)

        #expect(view.largeContentViewerInteraction(interaction, itemAt: point) != nil)
        try await waitUntil { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(60))
        try await waitUntil { clock.sleeperCount > 0 }

        #expect(view.isExpanded)

        view.largeContentViewerInteraction(interaction, didEndOn: capsule, at: point)
        #expect(tapped == 1)
        clock.advance(by: .seconds(1))
        try await waitUntil { !view.isExpanded }
    }
}
