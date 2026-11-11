import SciaTesting
import Testing
import UIKit
@testable import Scia

/// UIKitのスプリングを、打ち切らずに止まるところまで動かす。
@MainActor
@Suite(.failureState)
struct SpringToRestTests {
    /// ガラスのビューと、その中で逆向きに動く中身を、長い距離動かしても、動き終わりのコマで残りの分だけ飛ばない。
    /// UIKitのままでは、距離の約0.1%（300ptなら0.3pt）を残して打ち切り、最後のコマで目標へ飛ぶ。
    @Test func nestedMoveEndsWithoutJump() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let clock = LayerClock(freezing: window.layer)
        let bar = UIVisualEffectView(effect: UIGlassEffect())
        bar.frame = CGRect(x: 20, y: 100, width: 350, height: 400)
        let label = UIView(frame: CGRect(x: 16, y: 300, width: 200, height: 20))
        bar.contentView.addSubview(label)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        CATransaction.flush()

        UIView.animateSpringToRest(duration: 0.35, in: bar) {
            bar.frame = CGRect(x: 20, y: 460, width: 350, height: 40)
            label.frame.origin.y = 10
        }
        var positions: [CGFloat] = []
        for _ in 0..<120 {
            try await clock.advance(by: LayerClock.frame)
            positions.append(try presentedMinY(of: label, in: window))
        }

        let steps = zip(positions.dropFirst(), positions).map { $0 - $1 }
        // いちばん速いコマより後ろは、毎コマの動きが前のコマより大きくならずに減っていく。打ち切って飛ぶと、そのコマだけ大きく動く。
        let fastest = try #require(steps.indices.max { abs(steps[$0]) < abs(steps[$1]) })
        for (index, step) in steps.enumerated().dropFirst(fastest + 1) {
            #expect(abs(step) <= abs(steps[index - 1]) + 0.005, "\(index)コマ目で\(step)pt動きました（前のコマは\(steps[index - 1])pt）")
        }
        #expect(abs(try #require(positions.last) - 470) < 0.001)
    }

    /// UIKitの動きが終わり、続きがまだ動いている間に次の動きを始めても、見えている位置から始まる。
    /// UIKitは外れた動きと同じ名前を次の動きに使うので、続きも同じ名前にすると、前の続きを上書きして残りの分だけ飛ぶ。
    @Test func nextMoveDuringRestStartsFromShownPosition() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let clock = LayerClock(freezing: window.layer)
        let bar = UIVisualEffectView(effect: UIGlassEffect())
        bar.frame = CGRect(x: 20, y: 100, width: 350, height: 400)
        let label = UIView(frame: CGRect(x: 16, y: 300, width: 200, height: 20))
        bar.contentView.addSubview(label)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        CATransaction.flush()

        UIView.animateSpringToRest(duration: 0.35, in: bar) {
            bar.frame = CGRect(x: 20, y: 460, width: 350, height: 40)
            label.frame.origin.y = 10
        }
        // UIKitの動きが外れ、続きだけが残るまで進める。
        try await clock.advance {
            let keys = label.layer.animationKeys() ?? []
            return !keys.isEmpty && keys.allSatisfy { $0.hasPrefix("springToRest.") }
        }
        let shown = try presentedMinY(of: label, in: window)
        #expect(abs(shown - 470) > 0.01, "UIKitの動きが終わった時点で、続きが残っていません")

        UIView.animateSpringToRest(duration: 0.35, in: bar) {
            bar.frame = CGRect(x: 20, y: 100, width: 350, height: 400)
            label.frame.origin.y = 300
        }
        CATransaction.flush()
        #expect(abs(try presentedMinY(of: label, in: window) - shown) < 0.005)
    }

    /// 終わりの処理は、UIKitの動きが打ち切られた時点ではなく、続きも終えて止まってから呼ぶ。
    /// 打ち切られた時点で呼ぶと、そこで複製を外して本物を見せる動きで、続きの残りの差だけずれる。
    @Test func completionWaitsForRest() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let clock = LayerClock(freezing: window.layer)
        let bar = UIVisualEffectView(effect: UIGlassEffect())
        bar.frame = CGRect(x: 20, y: 100, width: 350, height: 400)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        CATransaction.flush()

        var finished: Bool?
        var shownAtCompletion: CGFloat?
        UIView.animateSpringToRest(duration: 0.35, in: bar) {
            bar.frame = CGRect(x: 20, y: 460, width: 350, height: 40)
        } completion: { result in
            finished = result
            shownAtCompletion = try? self.presentedMinY(of: bar, in: window)
        }
        try await clock.advance { finished != nil }

        #expect(finished == true)
        #expect(abs(try #require(shownAtCompletion) - 460) < 0.02)
        #expect(bar.layer.animationKeys()?.isEmpty ?? true)
    }

    private func presentedMinY(of view: UIView, in window: UIWindow) throws -> CGFloat {
        let layer = try #require(view.layer.presentation())
        let root = try #require(window.layer.presentation())
        return root.convert(layer.bounds, from: layer).minY
    }
}
