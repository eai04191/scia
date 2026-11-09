import Testing
@testable import SciaCore

struct InAppBrowserSheetLayoutTests {
    private let layout = InAppBrowserSheetLayout(collapsed: 76, medium: 500, large: 800)

    @Test func stopsAtNearestDetent() {
        #expect(layout.release(height: 120, velocity: 0, from: .medium) == .detent(.collapsed))
        #expect(layout.release(height: 450, velocity: 0, from: .medium) == .detent(.medium))
        #expect(layout.release(height: 700, velocity: 0, from: .medium) == .detent(.large))
    }

    @Test func velocityCarriesToNextDetent() {
        #expect(layout.release(height: 500, velocity: 1500, from: .medium) == .detent(.large))
        #expect(layout.release(height: 500, velocity: -2000, from: .medium) == .detent(.collapsed))
    }

    @Test func dismissesBelowHalfOfCollapsedHeight() {
        #expect(layout.release(height: 30, velocity: 0, from: .collapsed) == .dismiss)
        #expect(layout.release(height: 76, velocity: -600, from: .collapsed) == .dismiss)
    }

    @Test func flickFromMediumStopsAtCollapsed() {
        #expect(layout.release(height: 200, velocity: -3000, from: .medium) == .detent(.collapsed))
    }

    @Test func temporaryHeightRoundsToStepAwayFromOtherDetents() {
        #expect(layout.temporaryHeight(near: 301.5, step: 4) == 300)
        #expect(layout.temporaryHeight(near: 502, step: 4) == nil)
        #expect(layout.temporaryHeight(near: 78, step: 4) == nil)
        #expect(layout.temporaryHeight(near: 799, step: 4) == nil)
        #expect(InAppBrowserSheetLayout(collapsed: nil, medium: nil, large: 400).temporaryHeight(near: 200, step: 4) == nil)
    }

    @Test func temporaryDetentJoinsInHeightOrder() {
        let withPoint = layout.withTemporary(300)
        #expect(withPoint.detents == [.collapsed, .temporary, .medium, .large])
        #expect(withPoint.release(height: 305, velocity: 0, from: .medium) == .detent(.temporary))
        #expect(InAppBrowserSheetLayout(collapsed: nil, medium: nil, large: 400).withTemporary(300).detents == [.large])
    }

    @Test func fullScreenOnlyLayoutNeverDismisses() {
        let fullScreen = InAppBrowserSheetLayout(collapsed: nil, medium: nil, large: 400)
        #expect(fullScreen.detents == [.large])
        #expect(fullScreen.height(of: .collapsed) == 400)
        #expect(fullScreen.release(height: 10, velocity: -3000, from: .large) == .detent(.large))
    }
}
