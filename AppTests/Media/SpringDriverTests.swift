import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct SpringDriverTests {
    /// 上限を付けると、ひっかかりで間が空いても、1フレームで上限までしか進めない。ビューアの開き始めのように、一度に大きく進んで見えないようにする。
    @Test func longestElapsedKeepsStallFromJumping() {
        let frames = ManualFrameSource()
        let spring = SpringCurve(duration: 0.5, bounce: 0)
        var progress: [CGFloat] = []
        let driver = SpringDriver(spring: spring, source: frames, longestElapsed: 1.0 / 30) { progress.append($0) } completion: {}
        driver.start()

        frames.step(0.2)
        #expect(abs(Double(progress.last ?? 0) - spring.value(at: 1.0 / 30)) < 0.0001, "止まっていた分まで進みました: \(progress)")
        frames.step(0.2)
        #expect(abs(Double(progress.last ?? 0) - spring.value(at: 2.0 / 30)) < 0.0001)
        driver.stop()
    }

    /// 上限を付けなければ、間が空いても実際の時間で進め、決まった時間で落ち着かせる。
    @Test func withoutLimitFollowsActualTime() {
        let frames = ManualFrameSource()
        let spring = SpringCurve(duration: 0.5, bounce: 0)
        var progress: [CGFloat] = []
        let driver = SpringDriver(spring: spring, source: frames) { progress.append($0) } completion: {}
        driver.start()

        frames.step(0.2)
        #expect(abs(Double(progress.last ?? 0) - spring.value(at: 0.2)) < 0.0001)
        driver.stop()
    }
}
