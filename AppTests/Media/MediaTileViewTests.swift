import SciaCore
import Testing
import UIKit
@testable import Scia

/// サムネイルの印の写し。ビューアの開閉で動かす写しに載せ、サムネイルとのあいだで見え方がそろうことを確かめる。
@MainActor
struct MediaTileViewTests {
    /// 動画の再生マークも写しに載せる。載せないと、開き始めに再生マークが消え、閉じる着地で急に現れる。
    @Test func decorationCopyIncludesPlaySymbol() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(MediaAttachment(id: "1", type: .video, url: nil, previewUrl: nil), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()

        let copy = tile.makeDecorationCopy()

        let symbols = copy.subviews.compactMap { ($0 as? UIImageView)?.image }.filter(\.isSymbolImage)
        #expect(symbols.count == 1, "再生マークを写しに載せていません")
    }

    /// 画像には再生マークがないため、写しにも載せない。
    @Test func decorationCopyOfImageHasNoSymbol() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(MediaAttachment(id: "1", type: .image, url: nil, previewUrl: nil), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()

        let copy = tile.makeDecorationCopy()

        #expect(copy.subviews.compactMap { ($0 as? UIImageView)?.image }.allSatisfy { !$0.isSymbolImage })
    }

    /// 動画とGIFでは、サムネイルも写しに載せる。写しはビューアで再生していたコマを描くため、載せないと閉じる着地でサムネイルの絵に急に切り替わる。
    @Test func decorationCopyOfMovingMediaIncludesThumbnail() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(movingAttachment(type: .gifv), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()
        let thumbnail = tile.thumbnailImage

        let copy = tile.makeDecorationCopy()

        #expect(thumbnail != nil)
        #expect(copy.subviews.contains { ($0 as? UIImageView)?.image === thumbnail }, "サムネイルを写しに載せていません")
    }

    /// 画像では、写しとサムネイルが同じ絵なので載せない。載せると、透明な部分が重なって濃く見える。
    @Test func decorationCopyOfImageHasNoThumbnail() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(movingAttachment(type: .image), hiddenCount: 0, isCovered: false, policy: .offline)
        tile.layoutIfNeeded()
        let thumbnail = tile.thumbnailImage

        let copy = tile.makeDecorationCopy()

        #expect(thumbnail != nil)
        #expect(!copy.subviews.contains { ($0 as? UIImageView)?.image === thumbnail })
    }

    /// 通信せずにサムネイルを出すため、blurhashのぼかしを使う。
    private func movingAttachment(type: MediaAttachment.Kind) -> MediaAttachment {
        MediaAttachment(
            id: "1",
            type: type,
            url: nil,
            previewUrl: nil,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_600, height: 900)),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        )
    }
}
