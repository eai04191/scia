import Foundation
import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct AvatarViewTests {
    private let url = URL(string: "https://example.social/avatar.gif")

    /// 視差効果を減らす設定や、アニメーション画像を自動再生しない設定では、アイコンの設定で動かすことにしていても動かさない。
    @Test func animatedAvatarStaysStillWhenTheDeviceAsksForNoAnimatedImages() throws {
        let url = try #require(url)
        #expect(!AvatarView.key(url: url, animates: true, side: 40, scale: 2, playsAnimatedImages: false).animates)
        #expect(AvatarView.key(url: url, animates: true, side: 40, scale: 2, playsAnimatedImages: true).animates)
        #expect(!AvatarView.key(url: url, animates: false, side: 40, scale: 2, playsAnimatedImages: true).animates)
    }

    /// 表示している間に端末の設定が変わったら、動かすかどうかを決め直して読み直す。
    @Test func displayedAvatarFollowsTheDeviceSettingWhenItChanges() throws {
        var plays = true
        let view = AvatarView(store: AvatarImageStore { _ in Data() }, playsAnimatedImages: { plays })
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        view.apply(AvatarView.Content(url: url, shape: .circle, animates: true))
        #expect(view.loadingKey?.animates == true)

        plays = false
        NotificationCenter.default.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)

        #expect(view.loadingKey?.animates == false)
    }
}
