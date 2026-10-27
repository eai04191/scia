import Testing
import UIKit
@testable import Scia

/// トリミングの枠。回している間は、置かれているキャンバスごと縮めて回す。
@MainActor
struct CropOverlayViewTests {
    /// 四隅のハンドルと枠線。枠線は`dimViews`の後ろに足した5つ目の子で、ハンドルとグリッドの線はその子。ハンドルだけが白く塗られている。
    private func handles(of overlay: CropOverlayView) -> [UIView] {
        overlay.subviews[4].subviews.filter { $0.backgroundColor == .white }
    }

    /// キャンバスを縮めた倍率で、ハンドルを太く長く描き、画面の上では縮める前と同じ大きさに見せる。
    /// 縮めたまま描くと、回し始めのコマでハンドルが1コマで小さくなる。
    @Test func handlesKeepOnScreenSizeWhileScaled() {
        let overlay = CropOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        overlay.box = CGRect(x: 20, y: 200, width: 360, height: 200)
        overlay.layoutIfNeeded()
        let unscaled = handles(of: overlay).map(\.frame.size)

        overlay.drawingScale = 0.5

        let scaled = handles(of: overlay).map { CGSize(width: $0.frame.width * 0.5, height: $0.frame.height * 0.5) }
        #expect(scaled == unscaled)
        #expect(overlay.subviews[4].layer.borderWidth * 0.5 == 1)

        overlay.drawingScale = 1
        #expect(handles(of: overlay).map(\.frame.size) == unscaled)
    }

    /// 枠の外を暗くする覆いは、自分の外まで広がる。回している途中にキャンバスごと縮めても、画面の中の画像を暗くしたまま回すため。
    @Test func dimmingReachesBeyondBounds() {
        let overlay = CropOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        overlay.box = CGRect(x: 20, y: 200, width: 360, height: 200)
        overlay.layoutIfNeeded()
        let dims = overlay.subviews.prefix(4)
        let covered = dims.map(\.frame).reduce(CGRect.null) { $0.union($1) }

        #expect(covered.contains(overlay.bounds.insetBy(dx: -800, dy: -800)))
    }
}
