import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄の開閉で、カプセルと書いているときの行のあいだを動かす複製。
@MainActor
struct ComposeMorphFlightsTests {
    /// 行き先へ動かし始めたのと同じ回に行き先を測り直しても、複製は起点の形から動く。
    /// 書き終えたことが届いた直後に行が並べ直され、まだ一度も描いていない複製を止めると、
    /// 見えている形を読めずに行き先の値で止まり、閉じ始めに複製が行き先へ1コマで移っていた。
    @Test func retargetBeforeFirstDrawStartsFromSource() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let source = UIView(frame: CGRect(x: 16, y: 10, width: 64, height: 64))
        let target = UIView(frame: CGRect(x: 16, y: 300, width: 26, height: 26))
        container.addSubview(source)
        container.addSubview(target)
        let flights = ComposeMorphFlights(container: container)
        let key = ComposeMorphFlights.Key.chip
        func end(_ view: UIView) -> ComposeMorphFlights.End {
            .init(view: view, content: .thumbnail(nil, nil)) { view.alpha = $0 ? 0 : 1 }
        }

        flights.takeOff(from: [key: end(source)], stackingOrder: [key], stackShadowOpacity: 0)
        var generation = 0
        UIView.animate(withDuration: 1) {
            generation = flights.land(on: [key: end(target)], delays: [:], stackShadowOpacity: 0, duration: 1) { _, animations in animations() }
        }
        target.frame.origin.y = 320
        flights.retarget(on: [key: end(target)], generation: generation) { _, animations in
            UIView.animate(withDuration: 1, animations: animations)
        }

        let copies = container.subviews.flatMap(\.subviews).filter { $0 !== source && $0 !== target }
        let copy = try #require(copies.first)
        let move = try #require(copy.layer.animation(forKey: "position") as? CABasicAnimation)
        let from = try #require(move.fromValue as? CGPoint)
        // UIKitの動きは、行き先との差を足し合わせて動かす（`isAdditive`）。差から、動き始める位置を求める。
        let start = move.isAdditive ? CGPoint(x: copy.center.x + from.x, y: copy.center.y + from.y) : from
        #expect(start == CGPoint(x: source.frame.midX, y: source.frame.midY))
        #expect(copy.center == CGPoint(x: target.frame.midX, y: target.frame.midY))
    }
}
