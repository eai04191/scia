import SciaTesting
import Testing
import UIKit

extension UIViewController {
    /// テストで画面を動かさずに出し、出し終えるまで待つ。
    ///
    /// 動かさずに出しても、出し終えるのは次の描画の後になる。出る途中の画面の上に確認やシートを出そうとすると、UIKitは出さずに捨てる。
    /// 出した直後の待ちは、負荷のかかった実行では出し終える前に抜けることがあるため、時間や待ちの回数ではなく出し終えたことを条件にする。
    /// 出る途中の振る舞いを確かめるテストは、これを使わずに出し、その行で`present_without_waiting`を外す。
    func presentForTesting(_ viewController: UIViewController, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // swiftlint:disable:next present_without_waiting
        present(viewController, animated: false)
        try await waitUntil({ viewController.presentingViewController != nil && !viewController.isBeingPresented }, sourceLocation: sourceLocation)
    }

    /// テストで、この画面を動かさずに閉じ、閉じ終えるまで待つ。
    ///
    /// 動かさずに閉じても、閉じ終えるのは次の描画の後になる。閉じる途中の画面を出している画面には、ほかの画面を出せずにUIKitが捨てる。
    /// 閉じたあとに出した画面の上へ別の画面を出すテストは、時間で待たずに、閉じ終えたことを条件にする。
    func dismissForTesting(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        dismiss(animated: false)
        try await waitUntil({ presentingViewController == nil && !isBeingDismissed }, sourceLocation: sourceLocation)
    }
}
