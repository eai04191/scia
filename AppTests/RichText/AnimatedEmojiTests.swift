import Foundation
import ImageIO
import SciaCore
import SciaTesting
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Scia

/// `LinkLabel`の、アニメーションするカスタム絵文字。
@MainActor
struct AnimatedEmojiTests {
    private let font = UIFont.preferredFont(forTextStyle: .body)

    /// 元の画像を`.gif`、静止画を`.png`のURLにした絵文字。
    private func emoji(_ shortcode: String) throws -> CustomEmoji {
        CustomEmoji(
            shortcode: shortcode,
            url: try #require(URL(string: "https://example.social/emoji/\(shortcode).gif")),
            staticUrl: try #require(URL(string: "https://example.social/emoji/\(shortcode).png"))
        )
    }

    /// `frames`コマの、幅が高さの2倍の画像のデータ。`type`がGIFなら動く画像、PNGで1コマなら静止画になる。
    /// - Parameter delays: コマごとの秒数。省くとどのコマも0.1秒。
    private func imageData(_ type: UTType, frames: Int, delays: [Double]? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
        for index in 0..<frames {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
                UIColor(white: CGFloat(index) / CGFloat(frames), alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            }
            let delay = delays?[index] ?? 0.1
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, try #require(image.cgImage), properties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// `.gif`のURLには`gifFrames`コマのGIF、`.png`のURLには静止画を返すストア。
    private func store(gifFrames: Int = 3) throws -> EmojiImageStore<UIImage> {
        let gif = try imageData(.gif, frames: gifFrames)
        let png = try imageData(.png, frames: 1)
        return EmojiImageStore { url in url.pathExtension == "gif" ? gif : png }
    }

    /// 静止画とアニメーション版が届くまで待ってから、`text`を描いたラベル。
    /// - Parameter lineBreakMode: はみ出す分の扱い。本物の本文や名前と同じく、文字列の段落に入れる。UILabelは文字列を入れたときに、
    ///   段落の設定で自分の`lineBreakMode`を上書きするため、ラベルに入れても効かない。
    private func label(_ text: RichText, store: EmojiImageStore<UIImage>, numberOfLines: Int = 0, lineBreakMode: NSLineBreakMode = .byWordWrapping, width: CGFloat = 300) async throws -> LinkLabel {
        let renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: store, language: "ja")
        let emojis = text.blocks.flatMap(\.inlines).compactMap { inline -> CustomEmoji? in
            if case .emoji(let emoji) = inline { emoji } else { nil }
        }
        // 1回目で読み込みを始め、届くまで待つ。
        _ = renderer.render(text)
        for emoji in emojis {
            _ = store.animation(for: emoji.url)
        }
        try await waitUntil { emojis.allSatisfy { store.image(for: $0.staticUrl) != nil && store.hasFinishedLoadingAnimation(for: $0.url) } }
        let label = LinkLabel()
        label.numberOfLines = numberOfLines
        label.emojiImages = store
        let rendered = NSMutableAttributedString(attributedString: renderer.render(text))
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineBreakMode = lineBreakMode
            rendered.addAttribute(.paragraphStyle, value: style, range: range)
        }
        label.attributedText = rendered
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        label.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        label.layoutIfNeeded()
        return label
    }

    /// コマを送るアニメーションを付けた層。
    private func animatedLayers(of label: LinkLabel) -> [CALayer] {
        (label.layer.sublayers ?? []).filter { $0.animation(forKey: "frames") != nil && !$0.isHidden }
    }

    private func attachment(at index: Int, of label: LinkLabel) -> NSTextAttachment? {
        label.attributedText?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
    }

    /// 動く絵文字は、文字の中では同じ大きさの透明な画像で場所だけを取り、その位置に同じ大きさの、コマを送る層を重ねる。
    @Test func animatedEmojiIsDrawnByLayerOverAttachment() async throws {
        let crab = try emoji("crab")
        let store = try store()
        let label = try await label(RichText.plain("カニ :crab: です", emojis: [crab]), store: store)

        let layers = animatedLayers(of: label)
        #expect(layers.count == 1)
        let index = (label.attributedText?.string as NSString?)?.range(of: "\u{FFFC}").location ?? NSNotFound
        let placeholder = try #require(attachment(at: index, of: label))
        #expect(placeholder.image?.size == CGSize(width: 1, height: 1), "文字の中の画像は透明な場所取りに替える")
        let layer = try #require(layers.first)
        #expect(abs(layer.frame.width - placeholder.bounds.width) < 0.5)
        #expect(abs(layer.frame.height - placeholder.bounds.height) < 0.5)
        #expect(abs(layer.frame.height - font.lineHeight) < 0.5)
        #expect(layer.frame.minX > 0, "前の文字の後ろに置く")
        let animation = try #require(layer.animation(forKey: "frames") as? CAKeyframeAnimation)
        #expect(animation.values?.count == 3)
        #expect(animation.keyTimes?.count == 4)
    }

    /// セルを描き直して同じ文字列を渡し直しても、層を作り直さない。作り直すと、描き直すたびに層とアニメーションを作る手間がかかるため。
    @Test func sameTextKeepsLayers() async throws {
        let crab = try emoji("crab")
        let store = try store()
        let text = RichText.plain("カニ :crab:", emojis: [crab])
        let label = try await label(text, store: store)
        let before = animatedLayers(of: label)
        #expect(before.count == 1)

        label.attributedText = RichTextRenderer(font: font, textColor: .label, emojiImages: store, language: "ja").render(text)
        label.layoutIfNeeded()

        let after = animatedLayers(of: label)
        #expect(after.count == 1)
        #expect(after.first === before.first)
    }

    /// 裏から戻ったら、同じ文字列でも層を作り直す。裏に回っている間に、描画のサーバーがアニメーションを外していることがあるため。
    @Test func returningToForegroundRebuildsLayers() async throws {
        let crab = try emoji("crab")
        let label = try await label(RichText.plain("カニ :crab:", emojis: [crab]), store: store())
        let before = animatedLayers(of: label)
        #expect(before.count == 1)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        label.layoutIfNeeded()

        let after = animatedLayers(of: label)
        #expect(after.count == 1)
        #expect(after.first !== before.first)
    }

    /// メニューの動くアイコンは、いちばん短いコマを刻みにして、長いコマはその分だけ繰り返し、1周の長さを保つ。
    @Test func menuIconKeepsFrameDurations() throws {
        let animation = try #require(AnimatedImage.decode(imageData(.gif, frames: 2, delays: [0.1, 0.3]), maxPixelSize: 96))
        let icon = try #require(TimelineViewController.animatedMenuIcon(animation))

        #expect(icon.images?.count == 4)
        #expect(abs(icon.duration - 0.4) < 0.001)
    }

    /// コマが多い絵文字でも、メニューのアイコンの画像は300枚に収め、1周の長さは変えない。
    @Test func menuIconLimitsImagesWithoutSlowingDown() throws {
        let animation = try #require(AnimatedImage.decode(imageData(.gif, frames: 400), maxPixelSize: 96))
        let icon = try #require(TimelineViewController.animatedMenuIcon(animation))

        #expect(icon.images?.count == 300)
        #expect(abs(icon.duration - 40) < 0.001)
    }

    /// 重ねる色の付いた絵文字（編集履歴で足した絵文字）は、動く層の上に、その色の層を重ねる。
    @Test func tintedEmojiGetsTintLayerOverAnimation() async throws {
        let crab = try emoji("crab")
        let label = try await label(RichText.plain(":crab: :crab:", emojis: [crab]), store: store())
        // 1つ目の絵文字にだけ色を付けた文字列を入れ直す。
        let renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: try #require(label.emojiImages), language: "ja")
        let source = NSMutableAttributedString(attributedString: renderer.render(RichText.plain(":crab: :crab:", emojis: [crab])))
        source.addAttribute(.emojiTint, value: UIColor.green, range: (source.string as NSString).range(of: "\u{FFFC}"))
        label.attributedText = source
        label.layoutIfNeeded()

        let layers = animatedLayers(of: label)
        #expect(layers.count == 2)
        #expect(layers.filter { !($0.sublayers ?? []).isEmpty }.count == 1)
        let tinted = try #require(layers.first { !($0.sublayers ?? []).isEmpty })
        let tintLayer = try #require(tinted.sublayers?.first)
        #expect(tintLayer.frame == tinted.bounds, "色の層は絵文字の枠に重ねる")
        #expect(tintLayer.mask?.animation(forKey: "frames") != nil, "色は、絵文字と同じコマを送るマスクで、描かれている画素にだけかける")
        #expect(tintLayer.mask?.frame == tintLayer.bounds)
    }

    /// 同じ絵文字が続いても、1つずつ層を重ねる。
    @Test func repeatedEmojiGetsLayerEach() async throws {
        let crab = try emoji("crab")
        let label = try await label(RichText.plain(":crab::crab:", emojis: [crab]), store: store())

        let frames = animatedLayers(of: label).map(\.frame).sorted { $0.minX < $1.minX }
        #expect(frames.count == 2)
        #expect(frames.count == 2 && frames[0].maxX <= frames[1].minX + 0.5)
    }

    /// 1コマしかない画像は動かさず、文字の中の静止画のまま描く。
    @Test func stillEmojiKeepsImageInText() async throws {
        let still = try emoji("still")
        let label = try await label(RichText.plain("a :still: b", emojis: [still]), store: store(gifFrames: 1))

        #expect(animatedLayers(of: label).isEmpty)
        let index = (label.attributedText?.string as NSString?)?.range(of: "\u{FFFC}").location ?? NSNotFound
        #expect(attachment(at: index, of: label)?.image?.size != CGSize(width: 1, height: 1))
    }

    /// 文字列を替えたら、前の絵文字の層を外す。セルを使い回したときに、前の投稿の絵文字が残らないようにするため。
    @Test func replacingTextRemovesLayers() async throws {
        let crab = try emoji("crab")
        let label = try await label(RichText.plain("カニ :crab:", emojis: [crab]), store: store())
        #expect(animatedLayers(of: label).count == 1)

        label.attributedText = NSAttributedString(string: "絵文字なし")
        label.layoutIfNeeded()

        #expect(animatedLayers(of: label).isEmpty)
    }

    /// 「…」で切られているラベルでも、最後の行の、「…」の幅を足しても行に収まる絵文字は動かす。
    /// 切られて見えない行の絵文字には層を置かない。
    @Test func emojiBeforeEllipsisOnLastLineIsAnimated() async throws {
        let crab = try emoji("crab")
        let text = RichText(blocks: [.init(inlines: [.text("上 ", []), .emoji(crab), .lineBreak, .text("下 ", []), .emoji(crab), .lineBreak, .text("隠れる ", []), .emoji(crab)])])
        let label = try await label(text, store: store(), numberOfLines: 2, lineBreakMode: .byTruncatingTail)

        let layers = animatedLayers(of: label)
        #expect(layers.count == 2)
        #expect(layers.allSatisfy { label.bounds.contains($0.frame) })
    }

    /// 「…」で切られているラベルの最後の行で、行末に近く「…」に置き換わるかもしれない絵文字は、動かさず、文字の中の静止画のまま描く。
    @Test func emojiNearEllipsisOnLastLineKeepsStillImage() async throws {
        let crab = try emoji("crab")
        let text = RichText(blocks: [.init(inlines: [.text("上 ", []), .emoji(crab), .lineBreak, .text("下 ", []), .emoji(crab), .lineBreak, .text("隠れる ", []), .emoji(crab)])])
        // 広いラベルで最後の行の絵文字の右端を測り、そこに「…」が入らない幅にする。
        let wide = try await label(text, store: store(), numberOfLines: 2, lineBreakMode: .byTruncatingTail)
        let lastLineEmoji = try #require(animatedLayers(of: wide).max { $0.frame.midY < $1.frame.midY })
        let label = try await label(text, store: store(), numberOfLines: 2, lineBreakMode: .byTruncatingTail, width: lastLineEmoji.frame.maxX + 2)

        let layers = animatedLayers(of: label)
        #expect(layers.count == 1)
        #expect(layers.first.map { $0.frame.midY < label.bounds.midY } == true, "上の行の絵文字だけを動かす")
        let string = label.attributedText?.string as NSString?
        let first = string?.range(of: "\u{FFFC}").location ?? NSNotFound
        let second = string?.range(of: "\u{FFFC}", range: NSRange(location: first + 1, length: (string?.length ?? 0) - first - 1)).location ?? NSNotFound
        #expect(attachment(at: second, of: label)?.image?.size != CGSize(width: 1, height: 1), "最後の行の行末の絵文字は静止画を残す")
    }

    /// 1つの段落が折り返して「…」で切られるときも、最後の行の前のほうの絵文字は、UILabelが描く位置に重ねて動かす。
    /// TextKit 2は「…」で切る段落を折り返さずに1行に並べるため、そのままでは2行目より後の絵文字の位置が取れなかった。
    @Test func emojiOnLastLineOfWrappedTruncatedParagraphIsAnimated() async throws {
        let crab = try emoji("crab")
        let text = RichText.plain("1行目の文章がここにありますので、続けて書いていきます。2行目もまだまだ続いていく長めの文章です。3行目 :crab: そしてまだまだ長い文章が続くので、この行は最後に「…」で切られるはずです。", emojis: [crab])
        let label = try await label(text, store: store(), numberOfLines: 3, lineBreakMode: .byTruncatingTail)

        let layers = animatedLayers(of: label)
        #expect(layers.count == 1)
        #expect(layers.first.map { $0.frame.midY > label.bounds.height * 2 / 3 } == true, "3行目に重ねる")
    }

    /// 画面が左から右でも、右から左に書く段落の最後の行は、「…」が左の端に入るので、絵文字を動かさない。
    @Test func emojiOnLastLineOfRightToLeftParagraphKeepsStillImage() async throws {
        let crab = try emoji("crab")
        let text = RichText.plain("مرحبا :crab: هذا نص طويل جدا يستمر ويستمر حتى يتم قطعه في نهاية السطر الأخير من التسمية", emojis: [crab])
        let label = try await label(text, store: store(), numberOfLines: 1, lineBreakMode: .byTruncatingTail)

        #expect(animatedLayers(of: label).isEmpty)
    }

    /// 「…」で切るラベルでも、切られていなければ、最後の行の絵文字も動かす。
    @Test func lastLineOfUntruncatedLabelIsAnimated() async throws {
        let crab = try emoji("crab")
        let text = RichText(blocks: [.init(inlines: [.text("上 ", []), .emoji(crab), .lineBreak, .text("下 ", []), .emoji(crab)])])
        let label = try await label(text, store: store(), numberOfLines: 2, lineBreakMode: .byTruncatingTail)

        #expect(animatedLayers(of: label).count == 2)
    }

    /// 行末で切ってぼかすラベル（表示名）では、収まっている絵文字は動かし、行末ではみ出す絵文字は静止画のまま描く。
    @Test func clippedEmojiAtLineEndKeepsStillImage() async throws {
        let crab = try emoji("crab")
        let text = RichText.plain("カニ :crab: とても長い名前がここに続いて行末からはみ出す :crab:", emojis: [crab])
        let label = try await label(text, store: store(), numberOfLines: 1, lineBreakMode: .byClipping, width: 120)

        let layers = animatedLayers(of: label)
        #expect(layers.count == 1)
        #expect(layers.allSatisfy { label.bounds.contains($0.frame) })
    }

    /// ストアを渡していないラベルでは、絵文字は静止画のまま描く。
    @Test func labelWithoutStoreKeepsStillImage() async throws {
        let crab = try emoji("crab")
        let store = try store()
        let animated = try await label(RichText.plain(":crab:", emojis: [crab]), store: store)
        #expect(animatedLayers(of: animated).count == 1)

        animated.emojiImages = nil
        animated.attributedText = RichTextRenderer(font: font, textColor: .label, emojiImages: store, language: "ja").render(RichText.plain(":crab:", emojis: [crab]))
        animated.layoutIfNeeded()

        #expect(animatedLayers(of: animated).isEmpty)
    }
}
