import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 行より広いカスタム絵文字を、行の幅まで縮めて置く（`LineFittingAttachment`、`RichTextRenderer.fittingWideEmojis`）。
@MainActor
struct LineFittingAttachmentTests {
    private let font = UIFont.preferredFont(forTextStyle: .body)
    private let width: CGFloat = 328

    /// 縦横比`aspect`の画像の絵文字を読み込ませてから、`blocks`を描く。
    private func render(aspect: CGFloat, emojiOnly: Bool = false, _ blocks: (CustomEmoji) -> [RichText.Block]) async throws -> NSAttributedString {
        let url = try #require(URL(string: "https://example.social/emoji/wide\(aspect).png"))
        let emoji = CustomEmoji(shortcode: "wide", url: url, staticUrl: url)
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 10 * aspect, height: 10)).image { _ in }.pngData())
        let store = EmojiImageStore { _ in png }
        var renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: store, language: "ja")
        renderer.emojiOnly = emojiOnly ? EmojiOnlyEnlargement(scale: 2, limit: 10) : nil
        let text = RichText(blocks: blocks(emoji))
        _ = renderer.render(text)
        try await waitUntil { store.image(for: url, pixelHeight: EmojiImageStore<UIImage>.pixelHeight) != nil }
        return renderer.render(text)
    }

    private func label(_ text: NSAttributedString, drawsWithTextKit: Bool) -> LinkLabel {
        let label = LinkLabel()
        label.numberOfLines = 0
        label.drawsWithTextKit = drawsWithTextKit
        label.attributedText = text
        let height = label.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        label.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return label
    }

    /// `label`が並べた、カスタム絵文字の枠。ラベルの座標で返す。
    private func attachmentFrames(in label: LinkLabel, text: NSAttributedString) -> [CGRect] {
        let layout = label.textLayout(of: text)
        var frames: [CGRect] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value is LineFittingAttachment,
                  let location = layout.contentStorage.location(layout.contentStorage.documentRange.location, offsetBy: range.location),
                  let fragment = layout.layoutManager.textLayoutFragment(for: location)
            else { return }
            frames.append(fragment.frameForTextAttachment(at: location).offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY))
        }
        return frames
    }

    /// 引用やリストで字下げした段落でも、行より広い絵文字は、字下げを引いた行の幅に収まる。TextKitが渡す行の幅は字下げを引かないため。
    @Test(arguments: [false, true])
    func wideEmojiFitsTheIndentedLine(drawsWithTextKit: Bool) async throws {
        let text = try await render(aspect: 80) { emoji in
            [
                .init(inlines: [.text("引用 ", []), .emoji(emoji)], quoteLevel: 1),
                .init(inlines: [.text("リスト ", []), .emoji(emoji)], listMarker: "•", listLevel: 1),
                .init(inlines: [.emoji(emoji)]),
            ]
        }
        let frames = attachmentFrames(in: label(text, drawsWithTextKit: drawsWithTextKit), text: text)

        #expect(frames.count == 3)
        for frame in frames {
            #expect(frame.minX >= 0 && frame.maxX <= width + 0.01, "\(frame)")
        }
        #expect(abs((frames.last?.width ?? 0) - width) < 0.01, "字下げのない段落では行の幅いっぱいに縮める")
    }

    /// 縮めた絵文字だけの本文は、縮めた絵文字の高さの行に並ぶ。縮める前の大きさで付けた行の高さのままだと、絵文字の上が空く。
    @Test func emojiOnlyLineIsAsTallAsTheFittedEmoji() async throws {
        let text = try await render(aspect: 16, emojiOnly: true) { [.init(inlines: [.emoji($0)])] }
        let label = label(text, drawsWithTextKit: true)
        let frame = try #require(attachmentFrames(in: label, text: text).first)

        #expect(abs(frame.width - width) < 0.01)
        #expect(label.bounds.height < frame.height + 1, "行の高さ\(label.bounds.height) 絵文字\(frame)")
        #expect(frame.minY >= -0.01, "\(frame)")
    }

    /// 行に収まる絵文字の本文は、付け直さず、作った文字列をそのまま並べる。
    @Test func textWithoutWideEmojiIsLaidOutAsIs() async throws {
        let text = try await render(aspect: 1, emojiOnly: true) { [.init(inlines: [.emoji($0)])] }

        #expect(RichTextRenderer.fittingWideEmojis(in: text, width: width) === text)
    }

    /// 本文の字面の上下は、縮めて置いた絵文字の大きさで測る。縮める前の大きさで測ると、上下の部品とのあいだが縮めた分だけ空く。
    @Test func glyphInsetsAreMeasuredFromTheFittedEmoji() async throws {
        let text = try await render(aspect: 16, emojiOnly: true) { [.init(inlines: [.emoji($0)])] }
        let label = label(text, drawsWithTextKit: true)
        let frame = try #require(attachmentFrames(in: label, text: text).first)
        let baselines = label.textKitBaselines(width: width)

        let top = PostBodyView.textTopInset(of: text, width: width)
        let bottom = PostBodyView.textBottomInset(of: text, width: width)
        // 絵文字は字面より上下へ伸びるので、字面の上下は絵文字の上下の端になる。
        #expect(abs(top - (baselines.first - frame.minY)) < 0.5, "上\(top) ベースライン\(baselines.first) 絵文字\(frame)")
        #expect(abs(bottom - (frame.maxY - (label.bounds.height - baselines.lastFromBottom))) < 0.5, "下\(bottom) 絵文字\(frame)")
        #expect(top < PostBodyView.textTopInset(of: text))
    }
}
