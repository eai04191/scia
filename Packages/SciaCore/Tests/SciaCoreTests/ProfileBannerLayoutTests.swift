import CoreGraphics
import Testing
@testable import SciaCore

struct ProfileBannerLayoutTests {
    private func layout(_ aspect: Double?, lifts: Bool = true) -> ProfileBannerLayout {
        ProfileBannerLayout(width: 300, imageAspect: aspect, statusBarHeight: 60, navigationBarHeight: 50, liftsUnderBars: lifts)
    }

    @Test func standardBannerStartsBelowTheStatusBar() {
        // 3:1の画像は、ナビゲーションバーの高さの分だけ上がり、ステータスバーのすぐ下から始まる。
        #expect(layout(1.0 / 3) == ProfileBannerLayout(top: -50, height: 100))
    }

    @Test func bannerBeforeLoadingIsPlacedAsStandard() {
        #expect(layout(nil) == ProfileBannerLayout(top: -50, height: 100))
    }

    @Test func widerBannerIsPlacedAsStandard() {
        #expect(layout(1.0 / 4) == ProfileBannerLayout(top: -50, height: 100))
    }

    @Test func slightlyTallerBannerGrowsUpwardKeepingTheBottom() {
        // 高さ150は、ステータスバーの下からの100に足りるが、画面の上端（160）には届かない。
        let banner = layout(0.5)
        #expect(banner == ProfileBannerLayout(top: -100, height: 150))
        #expect(banner.bottom == 50)
    }

    @Test func tallBannerReachesTheScreenTopAndGrowsDownward() {
        // 高さ200は画面の上端から下端までの160を超えるため、画面の上端（-110）から置き、下へ広げる。
        let banner = layout(2.0 / 3)
        #expect(banner == ProfileBannerLayout(top: -110, height: 200))
    }

    @Test func veryTallBannerIsLimited() {
        #expect(layout(1) == ProfileBannerLayout(top: -110, height: 225))
    }

    @Test func bannerWithoutImageStaysBelowTheBars() {
        #expect(layout(0.5, lifts: false) == ProfileBannerLayout(top: 0, height: 100))
    }

    @Test func visibleRectCropsTheSidesOfAWiderImage() {
        // 4:1の画像を3:1の枠に置くと、左右が切れる。
        let rect = ProfileBannerLayout.visibleRect(ofImageSized: CGSize(width: 400, height: 100), inFrameWithAspect: 1.0 / 3)
        #expect(rect == CGRect(x: 50, y: 0, width: 300, height: 100))
    }

    @Test func visibleRectCropsTheTopAndBottomOfATallerImage() {
        let rect = ProfileBannerLayout.visibleRect(ofImageSized: CGSize(width: 300, height: 300), inFrameWithAspect: 0.75)
        #expect(rect == CGRect(x: 0, y: 37.5, width: 300, height: 225))
    }

    @Test func visibleRectIsTheWholeImageWhenTheAspectsMatch() {
        let rect = ProfileBannerLayout.visibleRect(ofImageSized: CGSize(width: 300, height: 100), inFrameWithAspect: 1.0 / 3)
        #expect(rect == CGRect(x: 0, y: 0, width: 300, height: 100))
    }
}
