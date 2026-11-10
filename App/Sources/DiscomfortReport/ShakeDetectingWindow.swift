import UIKit

/// シェイクで違和感レポートを開くウィンドウ。シェイクで開くのはデバッグ版だけ。DEBUGでコンパイルしないビルド（TestFlightなど）では、デバッグメニューをオンにしたときに、メニューから開く。
final class ShakeDetectingWindow: UIWindow {
    /// 表示中のアプリ内のSafariのシート。カスタムのプレゼンテーションでは、シートの外に触れたものをUIKitの入れ物のビューが受けて後ろへ通さないので、ここで通す。
    weak var browserPresentation: InAppBrowserPresentationController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let presentation = browserPresentation else { return super.hitTest(point, with: event) }
        if let grab = presentation.moveGrabTarget(at: point, in: self) { return grab }
        let hit = super.hitTest(point, with: event)
        guard hit === presentation.containerView, presentation.passesTouchesOutsideSheet, let behind = presentation.presentingViewController.viewIfLoaded else { return hit }
        return behind.hitTest(behind.convert(point, from: self), with: event)
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        #if DEBUG
        if motion == .motionShake {
            DiscomfortReportPresenter.present(in: self)
        }
        #endif
        super.motionEnded(motion, with: event)
    }
}
