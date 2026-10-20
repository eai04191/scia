import CoreGraphics
import Foundation
import Testing
@testable import SciaCore

struct MediaFocusTests {
    /// 投稿者が付けた焦点を読む。付けていない添付ファイルではnil。
    @Test func decodesFocusFromMeta() throws {
        let url = try #require(Bundle.module.url(forResource: "status_with_media", withExtension: "json", subdirectory: "Fixtures"))
        let status = try MastodonDecoder.make().decode(Status.self, from: Data(contentsOf: url))
        #expect(status.mediaAttachments[0].meta?.focus == MediaFocus(x: -0.27, y: 0.51))
        #expect(status.mediaAttachments[1].meta?.focus == nil)
    }

    /// 焦点がなければ、中央で切り抜く。
    @Test func centersWithoutFocus() {
        let frame = MediaFocus.fillFrame(imageSize: CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100), focus: nil)
        #expect(frame == CGRect(x: -50, y: 0, width: 200, height: 100))
    }

    /// 横長の画像を正方形に切り抜くとき、焦点が枠の中央に来るよう横にずらす。縦は枠に合わせる。
    @Test func movesFocusToCenter() {
        // 焦点は左から3/8、枠の中央（50）に来るよう、画像の左端を50 - 200 * 3/8 = -25に置く。
        let frame = MediaFocus.fillFrame(imageSize: CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100), focus: MediaFocus(x: -0.25, y: 0.9))
        #expect(frame == CGRect(x: -25, y: 0, width: 200, height: 100))
    }

    /// yは下から上へ増える。上寄りの焦点では、画像を下へずらして上の部分を見せる。
    @Test func treatsPositiveYAsUp() {
        // 焦点は上から1/4、枠の中央（50）に来るよう、画像の上端を50 - 200 * 1/4 = 0に置く。
        let frame = MediaFocus.fillFrame(imageSize: CGSize(width: 100, height: 200), in: CGRect(x: 0, y: 0, width: 100, height: 100), focus: MediaFocus(x: 0, y: 0.5))
        #expect(frame == CGRect(x: 0, y: 0, width: 100, height: 200))
    }

    /// 端に近い焦点でも、枠の中に画像のない部分を作らない。
    @Test func keepsImageCoveringBounds() {
        let size = CGSize(width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(MediaFocus.fillFrame(imageSize: size, in: bounds, focus: MediaFocus(x: -1, y: 0)) == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(MediaFocus.fillFrame(imageSize: size, in: bounds, focus: MediaFocus(x: 1, y: 0)) == CGRect(x: -100, y: 0, width: 200, height: 100))
        // 範囲の外の値も、端として扱う。
        #expect(MediaFocus.fillFrame(imageSize: size, in: bounds, focus: MediaFocus(x: 3, y: 0)) == CGRect(x: -100, y: 0, width: 200, height: 100))
    }

    /// 枠の原点がずれていても、枠からの位置で置く。
    @Test func offsetsByBoundsOrigin() {
        let frame = MediaFocus.fillFrame(imageSize: CGSize(width: 200, height: 100), in: CGRect(x: 10, y: 20, width: 100, height: 100), focus: nil)
        #expect(frame == CGRect(x: -40, y: 20, width: 200, height: 100))
    }

    /// レイヤーの`contentsRect`では、枠に見えている部分を画像の中の割合で表す。
    @Test func contentsRectSelectsVisiblePart() {
        let rect = MediaFocus.contentsRect(imageSize: CGSize(width: 200, height: 100), boundsSize: CGSize(width: 100, height: 100), focus: MediaFocus(x: -0.25, y: 0))
        #expect(rect == CGRect(x: 0.125, y: 0, width: 0.5, height: 1))
    }
}
