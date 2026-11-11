import ImageIO
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Scia

/// 同じ中身の文字列を入れ直したときに、ラベルが文字列を入れ替えず、測った結果を使い回すこと。
/// 行を組み直すたびに描き直す文字列は作り直され、絵文字の添付も毎回新しくなるので、渡されたもの同士の中身で比べる。
@Suite(.scratch, .failureState)
@MainActor
struct EmojiLabelReassignTests {
    private let font = UIFont.preferredFont(forTextStyle: .body)

    private func emoji(_ shortcode: String) throws -> CustomEmoji {
        let url = try #require(URL(string: "https://example.social/emoji/\(shortcode).png"))
        return CustomEmoji(shortcode: shortcode, url: url, staticUrl: url)
    }

    private func squarePNG() throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }.pngData())
    }

    /// 作り直した文字列でも、文字と属性が同じで、絵文字が同じ画像なら同じ中身とみなす。
    @Test func sameContentAcrossRenders() async throws {
        let blobcat = try emoji("blobcat")
        let png = try squarePNG()
        let store = EmojiImageStore { _ in png }
        let renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: store, language: "ja")
        let text = RichText.plain("前 :blobcat: 後ろ", emojis: [blobcat])
        let placeholder = renderer.render(text)
        #expect(EmojiLabel.hasSameContent(placeholder, renderer.render(text)))

        try await waitUntil { store.image(for: blobcat.staticUrl) != nil }
        let loaded = renderer.render(text)
        #expect(!EmojiLabel.hasSameContent(placeholder, loaded), "絵文字の画像が届いたのに同じとみなしています")
        #expect(EmojiLabel.hasSameContent(loaded, renderer.render(text)))

        let recolored = RichTextRenderer(font: font, textColor: .secondaryLabel, emojiImages: store, language: "ja").render(text)
        #expect(!EmojiLabel.hasSameContent(loaded, recolored))
        #expect(!EmojiLabel.hasSameContent(loaded, renderer.render(.plain("前 :blobcat: 後ろ。", emojis: [blobcat]))))
    }

    /// 同じ中身を入れ直しても、ラベルは文字列を入れ替えない。違う中身なら入れ替える。
    @Test func reassigningSameContentKeepsText() {
        let renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: EmojiImageStore { _ in Data() }, language: "ja")
        let label = LinkLabel()
        label.attributedText = renderer.render(.plain("本文", emojis: []))
        let shown = label.attributedText

        label.attributedText = renderer.render(.plain("本文", emojis: []))
        #expect(label.attributedText === shown, "同じ中身なのに文字列を入れ替えています")

        label.attributedText = renderer.render(.plain("別の本文", emojis: []))
        #expect(label.attributedText?.string == "別の本文")
    }

    /// 3コマのGIF。
    private func gifData() throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 3, nil))
        for index in 0..<3 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
                UIColor(white: CGFloat(index) / 3, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            }
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(destination, try #require(image.cgImage), properties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// アニメーション版を読めなかった絵文字は、間隔が過ぎてから同じ中身を入れ直すと読み直し、届いたら動かす。
    /// 入れ直しを省いても、入れ替えていたときと同じく読み直す。ウィンドウにないラベルは、ウィンドウに入ってから動かす。
    @Test func reassigningSameContentRetriesFailedAnimation() async throws {
        let crab = CustomEmoji(
            shortcode: "crab",
            url: try #require(URL(string: "https://example.social/emoji/crab.gif")),
            staticUrl: try #require(URL(string: "https://example.social/emoji/crab.png"))
        )
        let gif = try gifData()
        let png = try squarePNG()
        let gifReads = Mutex(0)
        let clock = TestClock()
        let store = EmojiImageStore(clock: clock, retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { url in
            guard url.pathExtension == "gif" else { return png }
            let isFirst = gifReads.withLock { reads in
                defer { reads += 1 }
                return reads == 0
            }
            if isFirst { throw URLError(.notConnectedToInternet) }
            return gif
        }
        let renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: store, language: "ja")
        let text = RichText.plain("カニ :crab:", emojis: [crab])
        _ = renderer.render(text)
        _ = store.animation(for: crab.url)
        try await waitUntil { store.image(for: crab.staticUrl) != nil && store.hasFinishedLoadingAnimation(for: crab.url) }
        let label = LinkLabel()
        label.emojiImages = store
        label.attributedText = renderer.render(text)
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 40)
        label.layoutIfNeeded()
        #expect(gifReads.withLock { $0 } == 1)

        // ストアは知らせを別のTaskで配る。ラベルより後に登録したので、読み直したアニメーション版の知らせがここに届いたら、ラベルにも届いている。
        let arrival = ArrivalRecorder()
        store.addListener(owner: arrival) { [weak arrival] urls in
            if urls.contains(crab.url), gifReads.withLock({ $0 }) == 2, store.hasFinishedLoadingAnimation(for: crab.url) {
                arrival?.delivered = true
            }
        }
        clock.advance(by: .seconds(5))
        label.attributedText = renderer.render(text)

        try await waitUntil { arrival.delivered }
        label.layoutIfNeeded()
        #expect(!(label.layer.sublayers ?? []).contains { $0.animation(forKey: "frames") != nil }, "ウィンドウにないラベルで動かしました")

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.addSubview(label)
        label.layoutIfNeeded()
        #expect((label.layer.sublayers ?? []).contains { $0.animation(forKey: "frames") != nil }, "ウィンドウに入っても動かしていません")
    }

    /// `text`で入れたあとに文字列を入れると、同じ文字でも入れ替える。
    @Test func attributedTextAfterPlainTextReplaces() {
        let label = EmojiLabel()
        let attributed = NSAttributedString(string: "本文", attributes: [.foregroundColor: UIColor.systemRed])
        label.attributedText = attributed
        label.text = "本文"
        label.attributedText = attributed
        #expect(label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .systemRed)
    }
}

/// 絵文字のストアの知らせが届いたかを記録する。
private final class ArrivalRecorder {
    var delivered = false
}
