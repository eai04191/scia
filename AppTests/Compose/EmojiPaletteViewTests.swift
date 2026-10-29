import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄の絵文字のパレット。
@MainActor
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

        // 画像が届く前にスクロールし、一覧に画面の下のセルを先に組み立てさせる。
        // 一覧は、スクロールが動いている間に、画面に入りそうなセルを先に組み立てる。
        let target = collectionView.contentOffset.y + 600
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        try await waitUntil { collectionView.contentOffset.y == target }

        gate.open()
        let urls = emojis.compactMap { emoji -> URL? in
            guard case .custom(let custom) = emoji else { return nil }
            return custom.staticUrl
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
