import SwiftUI
import UIKit

/// 今のウインドウでの、タブバーの形。設定の「タブ」の行のアイコンを、今の画面と同じ形にするのに使う。
struct TabBarShape: Equatable {
    /// ウインドウが縦長。端末の向きではなくウインドウで決める。iPadでは、横向きでもウインドウを縦長にできるため。
    var isPortrait = true
    /// タブバーが上に出ている。横幅の広いiPadのタブバー。
    var isAtTop = false

    init() {}

    init(windowSize: CGSize, traits: UITraitCollection) {
        isPortrait = windowSize.height >= windowSize.width
        isAtTop = Self.isAtTop(traits)
    }

    /// 横幅の広いiPadでは、タブバーが上に出て横にスクロールする。
    static func isAtTop(_ traits: UITraitCollection) -> Bool {
        traits.userInterfaceIdiom == .pad && traits.horizontalSizeClass == .regular
    }

    /// 枠の向きと帯の位置が、今のタブバーと同じシンボル。
    var symbolName: String {
        switch (isPortrait, isAtTop) {
        case (true, false): "rectangle.portrait.bottomthird.inset.filled"
        case (true, true): "rectangle.portrait.topthird.inset.filled"
        case (false, false): "rectangle.bottomthird.inset.filled"
        case (false, true): "rectangle.topthird.inset.filled"
        }
    }
}

/// 今のタブバーの形を、SwiftUIの画面へ伝える。
@MainActor
@Observable
final class TabBarShapeModel {
    private(set) var shape = TabBarShape()

    func update(_ shape: TabBarShape) {
        guard shape != self.shape else { return }
        self.shape = shape
    }
}

/// 載せた先の大きさが変わるたびに呼ぶ、何も描かないビュー。ウインドウの大きさの変化は、トレイトの変化では届かないため。
@MainActor
final class LayoutObserverView: UIView {
    var onLayout: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayout()
    }
}
