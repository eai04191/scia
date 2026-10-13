import UIKit

/// シェイクで違和感レポートを開くウィンドウ。
final class ShakeDetectingWindow: UIWindow {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            DiscomfortReportPresenter.present(in: self)
        }
        super.motionEnded(motion, with: event)
    }
}
