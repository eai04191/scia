import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄の絵文字のパレット。
@MainActor
@Suite(.failureState)
struct EmojiPaletteViewTests {
    /// 画面に入る前に組み立てたセルも、画像が届いたら描き直し、画面に入ったときに画像で描く。
    /// 画面に見えているセルだけを描き直していたため、スクロールで先に組み立てたセルは、画像が届いても空のまま画面に出ていた。
    @Test func cellPreparedBeforeImageArrivesShowsTheImage() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let gate = Gate()
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.pngData())
        let store = EmojiImageStore { _ in
            try await gate.wait()
            return png
        }
        let palette = EmojiPaletteView(emojiImages: store)
        palette.frame = window.bounds
        window.addSubview(palette)
        let base = URL(filePath: "/")
        let emojis = (0..<400).map { index in
            let name = String(format: "emoji%03d", index)
            return PaletteEmoji.custom(ServerEmoji(shortcode: name, url: base.appending(path: "\(name).gif"), staticUrl: base.appending(path: "\(name).png")))
        }
        palette.setContent(.sections([EmojiPaletteSection(kind: .uncategorized, emojis: emojis)], customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)

        // 画像が届く前にスクロールし、パレットに画面の下のセルを先に組み立てさせる。
        // パレットはスクロールが動いている間に、画面に入りそうなセルを先に組み立てる。
        let target = collectionView.contentOffset.y + 600
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        try await waitUntil { collectionView.contentOffset.y == target }

        gate.open()
        let urls = emojis.compactMap { emoji -> URL? in
            guard case .custom(let custom) = emoji else { return nil }
            // パレットは絵文字を動かすので、元の画像を読む。
            return custom.url
        }
        // パレットより後に登録したので、ここに知らせが届いたときには、パレットも描き直し終えている。
        var notified: Set<URL> = []
        store.addListener(owner: palette) { notified.formUnion($0) }
        try await waitUntil { urls.allSatisfy { store.image(for: $0) != nil } && notified.isSuperset(of: urls) }

        collectionView.contentOffset.y += collectionView.bounds.height
        collectionView.layoutIfNeeded()
        let blank = Self.cells(in: collectionView).filter { Self.isVisible($0, in: collectionView) && Self.imageView(of: $0)?.image == nil }
        #expect(blank.isEmpty, "画像が届いたのに空のまま画面に出たセル: \(blank.compactMap(\.accessibilityLabel))")
    }

    /// 静止画がまだ届いていない絵文字は、小さい静止画で描き、静止画が届いたら差し替える。
    /// 速く流したときに、ファイルの読み出しや展開を待って枠が空いたまま見えないようにするため。
    @Test(.scratch) func drawsThumbnailUntilStillArrives() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let gate = Gate()
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }.pngData())
        let store = EmojiImageStore { _ in
            try await gate.wait()
            return png
        }
        let thumbnails = EmojiThumbnails(file: TestScratch.url("EmojiPaletteViewTests").appending(path: "thumbnails.bin"), pixelHeight: 8)
        let base = URL(filePath: "/")
        let emoji = ServerEmoji(shortcode: "blob", url: base.appending(path: "blob.gif"), staticUrl: base.appending(path: "blob.png"))
        thumbnails.add(emoji.url, image: try #require(UIImage(data: png)?.cgImage))
        try await waitUntil { thumbnails.contains(emoji.url) }
        let palette = EmojiPaletteView(emojiImages: store, thumbnails: thumbnails, thumbnailBuilder: nil)
        palette.frame = window.bounds
        window.addSubview(palette)
        palette.setContent(.sections([EmojiPaletteSection(kind: .uncategorized, emojis: [.custom(emoji)])], customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)
        let cell = try #require(Self.cells(in: collectionView).first)

        #expect(Self.imageView(of: cell)?.image?.cgImage?.height == 8, "静止画が届く前は、小さい静止画で描く")

        gate.open()
        try await waitUntil { store.image(for: emoji.url) != nil && Self.imageView(of: cell)?.image?.cgImage?.height == 96 }
    }

    /// Unicodeの絵文字は、画像ができるまで空けておき、できたら見えているセルに入れる。
    /// 文字として描いていたときは、セルを画面に出すフレームで絵を作り、速いスクロールでフレームが落ちた。
    @Test func standardEmojiAppearsWhenItsImageIsReady() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let gate = Gate()
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        let glyphs = EmojiGlyphImageStore { _ in
            try? await gate.wait()
            return drawn
        }
        let palette = EmojiPaletteView(emojiImages: EmojiImageStore { _ in throw CancellationError() }, glyphImages: glyphs)
        palette.frame = window.bounds
        window.addSubview(palette)
        let emojis = ["😀", "😃", "😄"].map { PaletteEmoji.standard(StandardEmoji(emoji: $0, name: $0, keywords: [], version: "1.0")) }
        palette.setContent(.sections([EmojiPaletteSection(kind: .standard("顔と感情"), emojis: emojis)], customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)
        let cells = Self.cells(in: collectionView)
        #expect(cells.count == emojis.count)
        #expect(cells.allSatisfy { Self.glyphView(of: $0)?.image == nil })

        gate.open()
        try await waitUntil { cells.allSatisfy { Self.glyphView(of: $0)?.image === drawn } }
    }

    private static func glyphView(of cell: UICollectionViewCell) -> UIImageView? {
        cell.contentView.subviews.filter { type(of: $0) == UIImageView.self }.compactMap { $0 as? UIImageView }.first
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private static func cells(in collectionView: UICollectionView) -> [EmojiPaletteCell] {
        collectionView.subviews.compactMap { $0 as? EmojiPaletteCell }.filter { !$0.isHidden }
    }

    private static func isVisible(_ cell: UICollectionViewCell, in collectionView: UICollectionView) -> Bool {
        collectionView.bounds.intersects(cell.frame)
    }

    private static func imageView(of cell: UICollectionViewCell) -> UIImageView? {
        cell.contentView.subviews.compactMap { $0 as? UIImageView }.first
    }
}
