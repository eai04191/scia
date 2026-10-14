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
        tile.apply(MediaAttachment(id: "1", type: .video, url: nil, previewUrl: nil), hiddenCount: 0, isCovered: false)
        tile.layoutIfNeeded()

        let copy = tile.makeDecorationCopy()

        let symbols = copy.subviews.compactMap { ($0 as? UIImageView)?.image }.filter(\.isSymbolImage)
        #expect(symbols.count == 1, "再生マークを写しに載せていません")
    }

    /// 画像には再生マークがないため、写しにも載せない。
    @Test func decorationCopyOfImageHasNoSymbol() {
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        tile.apply(MediaAttachment(id: "1", type: .image, url: nil, previewUrl: nil), hiddenCount: 0, isCovered: false)
        tile.layoutIfNeeded()

        let copy = tile.makeDecorationCopy()

        #expect(copy.subviews.compactMap { ($0 as? UIImageView)?.image }.allSatisfy { !$0.isSymbolImage })
    }
}
