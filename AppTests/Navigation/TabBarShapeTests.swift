import Testing
import UIKit
@testable import Scia

/// 設定の「タブ」の行のアイコンを決める、今のウインドウでのタブバーの形。
@MainActor
@Suite(.failureState)
struct TabBarShapeTests {
    private func traits(_ idiom: UIUserInterfaceIdiom, _ horizontal: UIUserInterfaceSizeClass) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceIdiom = idiom
            traits.horizontalSizeClass = horizontal
        }
    }

    /// 枠の向きは、端末ではなくウインドウの縦横で決まる。
    @Test func frameFollowsTheWindow() {
        #expect(TabBarShape(windowSize: CGSize(width: 402, height: 874), traits: traits(.phone, .compact)).isPortrait)
        #expect(!TabBarShape(windowSize: CGSize(width: 874, height: 402), traits: traits(.phone, .compact)).isPortrait)
        // 横向きのiPadの中の、縦長のウインドウ。
        #expect(TabBarShape(windowSize: CGSize(width: 403, height: 714), traits: traits(.pad, .compact)).isPortrait)
    }

    /// 帯が上になるのは、横幅の広いiPadだけ。iPadでも幅の狭いウインドウと、横幅の広いiPhoneの横向きでは下。
    @Test func bandIsAtTopOnlyOnWidePad() {
        #expect(TabBarShape(windowSize: CGSize(width: 744, height: 1133), traits: traits(.pad, .regular)).isAtTop)
        #expect(!TabBarShape(windowSize: CGSize(width: 403, height: 714), traits: traits(.pad, .compact)).isAtTop)
        #expect(!TabBarShape(windowSize: CGSize(width: 956, height: 440), traits: traits(.phone, .regular)).isAtTop)
    }

    /// 4通りの形のシンボルが、どれもiOSにあり、互いに違う。`Image(systemName:)`は、ない名前を渡しても何も描かないだけになるため。
    @Test func everyShapeHasItsOwnSymbol() {
        var names: Set<String> = []
        for isPortrait in [true, false] {
            for isAtTop in [true, false] {
                var shape = TabBarShape()
                shape.isPortrait = isPortrait
                shape.isAtTop = isAtTop
                #expect(UIImage(systemName: shape.symbolName) != nil, "\(shape.symbolName)")
                names.insert(shape.symbolName)
            }
        }
        #expect(names.count == 4)
    }
}
