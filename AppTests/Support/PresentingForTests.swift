import Testing
import UIKit

extension UIViewController {
    /// テストで画面を動かさずに出し、出し終えるまで待つ。
    ///
    /// 動かさずに出しても、出し終えるのは次の描画の後になる。出る途中の画面の上に確認やシートを出そうとすると、UIKitは出さずに捨てる。
    /// 出した直後の待ちは、負荷のかかった実行では出し終える前に抜けることがあるため、時間や待ちの回数ではなく出し終えたことを条件にする。
    /// 出る途中の振る舞いを確かめるテストは、これを使わずに出し、その行で`present_without_waiting`を外す。
    func presentForTesting(_ viewController: UIViewController, timeout: Duration = .seconds(3), sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // swiftlint:disable:next present_without_waiting
        present(viewController, animated: false)
        let deadline = ContinuousClock.now + timeout
        while viewController.presentingViewController == nil || viewController.isBeingPresented {
            guard ContinuousClock.now < deadline else {
                Issue.record("画面を出し終えないまま時間切れになりました: \(type(of: viewController))", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
