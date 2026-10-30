import SciaCore
import Testing
import UIKit
@testable import Scia

/// メディアのメニューから始めた共有と、持ち上げた画像の読み直しを確かめる。メニューの組み方は、SciaCoreの`MediaMenuTreeTests`で確かめる。
@MainActor
struct MediaMenuTests {
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private final class Thumbnail: UIImageView, MediaViewerSource {}

    private func makeWindow() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        return UIWindow(windowScene: scene)
    }

    /// 一覧から共有を始めたあと、落としている間にサムネイルが別の投稿に使い回されても、共有シートには始めたときの画像を添え、
    /// 別の画像を出しているサムネイルを起点にしない。
    @Test func sharingFromMenuKeepsStartingPreviewWhenThumbnailIsReused() throws {
        let original = image(.red)
        let window = try makeWindow()
        let thumbnail = Thumbnail(image: image(.blue))
        window.addSubview(thumbnail)
        let file = URL(filePath: "/tmp/1.png")

        let content = MediaTransferCenter.menuShareSheet(file: file, startedWith: original, source: thumbnail)

        #expect((content.item as? MediaShareSheetItem)?.preview === original)
        #expect(content.anchor == nil)
    }

    /// 同じ画像を出しているサムネイルは、共有シートの起点にする。
    @Test func sharingFromMenuAnchorsToUnchangedThumbnail() throws {
        let original = image(.red)
        let window = try makeWindow()
        let thumbnail = Thumbnail(image: original)
        window.addSubview(thumbnail)

        let content = MediaTransferCenter.menuShareSheet(file: URL(filePath: "/tmp/1.png"), startedWith: original, source: thumbnail)

        #expect(content.anchor === thumbnail)
    }

    /// 持ち上げた画像の読み直しは、画面に収まる大きさに合わせ、ビューアと同じ上限を超えない。
    @Test func sharperImageFitsScreenAndViewerLimit() {
        let screen = CGSize(width: 390, height: 844)
        // 縦横比1:20の画像は、画面の幅のまま縦に長い大きさを渡すが、読むのは画面の高さに収まる大きさまで。
        #expect(MediaMenuInteraction.sharperPixelSize(previewSize: CGSize(width: 390, height: 7800), within: screen, scale: 3) == 2532)
        // 画面に収まる大きさでも、ビューアの上限を超えない。
        #expect(MediaMenuInteraction.sharperPixelSize(previewSize: CGSize(width: 2000, height: 1000), within: CGSize(width: 2000, height: 2000), scale: 3) == MediaImagePixelSize.full)
        // 画面に収まる横長の画像は、渡した大きさのまま読む。
        #expect(MediaMenuInteraction.sharperPixelSize(previewSize: CGSize(width: 390, height: 219), within: screen, scale: 3) == 1170)
    }
}
