import SciaCore
import Testing
import UIKit
@testable import Scia

/// サムネイルに重ねた表示の複製。ビューアの開閉で動かす複製に載せ、サムネイルとのあいだで見え方がそろうことを確かめる。
@MainActor
struct MediaTileViewTests {
    /// 動画の再生マークも複製に載せる。載せないと、開き始めに再生マークが消え、閉じる着地で急に現れる。
    @Test func decorationCopyIncludesPlaySymbol() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(MediaAttachment(id: "1", type: .video, url: nil, previewUrl: nil), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()

        let copy = tile.makeDecorationCopy()

        let symbols = Self.images(in: copy).filter(\.isSymbolImage)
        #expect(symbols.count == 1, "再生マークを複製に載せていません")
    }

    /// 画像には再生マークがないため、複製にも載せない。
    @Test func decorationCopyOfImageHasNoSymbol() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(MediaAttachment(id: "1", type: .image, url: nil, previewUrl: nil), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()

        let copy = tile.makeDecorationCopy()

        #expect(Self.images(in: copy).allSatisfy { !$0.isSymbolImage })
    }

    /// 動画とGIFでは、サムネイルも複製に載せる。複製はビューアで再生していたコマを描くため、載せないと閉じる着地でサムネイルの絵に急に切り替わる。
    @Test func decorationCopyOfMovingMediaIncludesThumbnail() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(movingAttachment(type: .gifv), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()
        let thumbnail = tile.thumbnailImage

        let copy = tile.makeDecorationCopy()

        #expect(thumbnail != nil)
        #expect(copy.subviews.contains { ($0 as? FocusCroppedImageView)?.image === thumbnail }, "サムネイルを複製に載せていません")
    }

    /// 画像では、複製とサムネイルが同じ絵なので載せない。載せると、透明な部分が重なって濃く見える。
    @Test func decorationCopyOfImageHasNoThumbnail() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(movingAttachment(type: .image), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()
        let thumbnail = tile.thumbnailImage

        let copy = tile.makeDecorationCopy()

        #expect(thumbnail != nil)
        #expect(!copy.subviews.contains { ($0 as? FocusCroppedImageView)?.image === thumbnail })
    }

    /// 動画とGIFのサムネイルの複製も、サムネイルと同じ焦点で切り抜く。違うと、閉じる着地で絵がずれる。
    @Test func decorationCopyKeepsFocus() throws {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        let focus = MediaFocus(x: 0.3, y: -0.6)
        tile.apply(movingAttachment(type: .gifv, focus: focus), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()

        let copy = try #require(tile.makeDecorationCopy().subviews.compactMap { $0 as? FocusCroppedImageView }.first)

        #expect(tile.thumbnailFocus == focus)
        #expect(copy.focus == focus)
    }

    /// 通信せずにサムネイルを出すため、blurhashのぼかしを使う。
    private func movingAttachment(type: MediaAttachment.Kind, focus: MediaFocus? = nil) -> MediaAttachment {
        MediaAttachment(
            id: "1",
            type: type,
            url: nil,
            previewUrl: nil,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_600, height: 900), focus: focus),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        )
    }

    /// 複製の中の画像を、入れ子のビューまで含めて集める。再生マークは丸のビューの中に三角を入れて載せるため。
    private static func images(in view: UIView) -> [UIImage] {
        view.subviews.flatMap { subview in
            [(subview as? UIImageView)?.image].compactMap(\.self) + images(in: subview)
        }
    }
}
