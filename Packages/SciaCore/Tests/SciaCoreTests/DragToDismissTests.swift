import Testing
@testable import SciaCore

struct DragToDismissTests {
    private let drag = DragToDismiss(distanceThreshold: 0.15, velocityThreshold: 1, smallestScale: 0.5, fadeDistance: 0.5, restoreDuration: 0.35)

    @Test func dismissesWhenMovedPastDistanceThreshold() {
        #expect(drag.shouldDismiss(translation: 150, velocity: 0, height: 1000))
        #expect(!drag.shouldDismiss(translation: 149, velocity: 0, height: 1000))
    }

    /// 同じ距離でも、画面の高さに対する割合で判定する。
    @Test func distanceThresholdScalesWithScreenHeight() {
        #expect(!drag.shouldDismiss(translation: 150, velocity: 0, height: 2000))
        #expect(drag.shouldDismiss(translation: 300, velocity: 0, height: 2000))
    }

    @Test func dismissesOnFastDownwardFlickEvenIfShort() {
        #expect(drag.shouldDismiss(translation: 20, velocity: 1000, height: 1000))
        #expect(!drag.shouldDismiss(translation: 20, velocity: 999, height: 1000))
    }

    @Test func staysOpenWhenFlickedBackUp() {
        #expect(!drag.shouldDismiss(translation: 400, velocity: -1000, height: 1000))
        #expect(drag.shouldDismiss(translation: 400, velocity: -999, height: 1000))
    }

    @Test func staysOpenWhenMovedUp() {
        #expect(!drag.shouldDismiss(translation: -300, velocity: 0, height: 1000))
    }

    @Test func shrinksInProportionToDistanceUntilOneScreen() {
        #expect(drag.scale(translation: 0, height: 1000) == 1)
        #expect(drag.scale(translation: 500, height: 1000) == 0.75)
        #expect(drag.scale(translation: 1000, height: 1000) == 0.5)
        #expect(drag.scale(translation: 2000, height: 1000) == 0.5)
        #expect(drag.scale(translation: -300, height: 1000) == 1)
    }

    @Test func fadesBackgroundUntilFadeDistance() {
        #expect(drag.backgroundAlpha(translation: 0, height: 1000) == 1)
        #expect(drag.backgroundAlpha(translation: 250, height: 1000) == 0.5)
        #expect(drag.backgroundAlpha(translation: 500, height: 1000) == 0)
        #expect(drag.backgroundAlpha(translation: 800, height: 1000) == 0)
        #expect(drag.backgroundAlpha(translation: -300, height: 1000) == 1)
    }
}
