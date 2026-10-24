#if DEBUG
import UIKit

/// 素材を切り出す目印。画面全体を0.3秒だけマゼンタで覆う。`Tools/promo-record.sh`が、録画の中からこの色のコマを探し、
/// 1つ目の目印が消えたところから、2つ目の目印が出るところまでを素材にする。
///
/// 録画の時刻は、画面が長く変わらない間にMacの時計と合わなくなることがあり、シナリオが出した時刻で切り出すと、数秒から10秒ずれた。
@MainActor
enum ScenarioMarker {
    static func flash() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = UIColor(red: 1, green: 0, blue: 1, alpha: 1)
        cover.isUserInteractionEnabled = false
        window.addSubview(cover)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            cover.removeFromSuperview()
        }
    }
}
#endif
