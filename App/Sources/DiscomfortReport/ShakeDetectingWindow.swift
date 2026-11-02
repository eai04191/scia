import UIKit

/// シェイクで違和感レポートを開くウィンドウ。違和感レポートは開発のための機能なので、DEBUGでコンパイルしないビルド（TestFlightなど）では開かない。
final class ShakeDetectingWindow: UIWindow {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        #if DEBUG
        if motion == .motionShake {
            DiscomfortReportPresenter.present(in: self)
        }
        #endif
        super.motionEnded(motion, with: event)
    }
}
