#if DEBUG
import Foundation
import ObjectiveC
import os
import SciaCore

/// MacでDesigned for iPadとして動かすとき、約77%に縮小して描かれるのをやめさせ、等倍でくっきり描かせる。
/// 縮小率を返す非公開のメソッドを、常に1を返す実装に差し替える。非公開APIなのでDEBUGに限る。
/// macOSの更新でクラスやメソッドがなくなったら、差し替えずにログを出し、標準の縮小表示のまま動かす。
@MainActor
enum MacNativeScale {
    private static var installed = false
    private static let logger = SciaLog.logger(category: "mac")

    /// 差し替える非公開のメソッド。cinderella-project/iMastのAppDelegateにならった
    private static let targets: [(className: String, selector: String)] = [
        ("UINSSceneView", "sceneToSceneViewScaleFactor"),
        ("UINSSceneView", "fixedSceneToSceneViewScaleFactor"),
        ("UINSSceneContainerView", "sceneToSceneViewScaleForLayout"),
    ]

    static func installIfOnMac() {
        guard ProcessInfo.processInfo.isiOSAppOnMac, !installed else { return }
        installed = true

        // 一部だけ差し替えると、描く大きさとレイアウトの大きさが食い違うため、全部見つかったときだけ差し替える
        var methods: [Method] = []
        for target in targets {
            guard let targetClass = NSClassFromString(target.className),
                  let method = class_getInstanceMethod(targetClass, NSSelectorFromString(target.selector))
            else {
                logger.error("等倍表示にできない: \(target.className, privacy: .public).\(target.selector, privacy: .public)がない")
                return
            }
            methods.append(method)
        }
        let one: @convention(block) (AnyObject) -> CGFloat = { _ in 1 }
        let implementation = imp_implementationWithBlock(one)
        for method in methods {
            method_setImplementation(method, implementation)
        }
    }
}
#endif
