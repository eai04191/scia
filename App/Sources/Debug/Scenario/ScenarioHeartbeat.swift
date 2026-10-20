#if DEBUG
import QuartzCore
import UIKit

/// 撮影モードの間、画面の左上の隅の1ptを、見分けられないほどわずかに毎コマ変え続ける。
///
/// `simctl io recordVideo`は画面が変わったときだけコマを書き、画面がしばらく変わらないと、その間の時間が録画から消えた
/// （目印を出したあと止まっていた約3秒が消え、目印の直後のコマにもう新着が入っていた）。毎コマ変えておくと、毎コマ書かれて時間が消えない。
/// 白い地と黒い地のどちらでも変わるよう、白と黒をごく薄く重ねた点を、濃さを交互に替える。隅は端末の角の丸みに隠れる場所。
@MainActor
enum ScenarioHeartbeat {
    private static var link: CADisplayLink?
    private static let dots = [UIView(), UIView()]
    private static var tick = false

    static func start() {
        guard link == nil else { return }
        dots[0].backgroundColor = .white
        dots[1].backgroundColor = .black
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index), y: 0, width: 1, height: 1)
            dot.isUserInteractionEnabled = false
        }
        let link = CADisplayLink(target: Ticker.shared, selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate static func step() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        tick.toggle()
        for dot in dots {
            if dot.superview !== window {
                window.addSubview(dot)
            }
            // 画面を重ねて開いても隠れないよう、毎コマいちばん上へ出す
            window.bringSubviewToFront(dot)
            dot.alpha = tick ? 0.02 : 0.04
        }
    }

    @MainActor
    private final class Ticker: NSObject {
        static let shared = Ticker()
        @objc func tick(_ link: CADisplayLink) {
            ScenarioHeartbeat.step()
        }
    }
}
#endif
