import SciaCore
import UIKit

/// RichTextを、UILabelに渡せるNSAttributedStringにする。
@MainActor
struct RichTextRenderer {
    var font: UIFont
    var textColor: UIColor
    var secondaryColor: UIColor = .secondaryLabel
    var linkColor: UIColor = .tintColor
    var paragraphSpacing: CGFloat = 0
    /// 行と行のあいだに足す余白。
    var lineSpacing: CGFloat = 0
    /// 引用とリストの1段あたりの字下げ。
    var indentPerLevel: CGFloat = 16
    /// カスタム絵文字の高さの、Unicodeの絵文字を文字の大きさのまま描いたときの絵の高さ（`EmojiFont.glyphHeight`）に対する割合。
    var emojiScale: CGFloat = 1
    /// Unicodeの絵文字の絵の高さの、文字の大きさのまま描いたときの絵の高さに対する割合。カスタム絵文字と同じ割合なら、同じ高さに描く。
    var unicodeEmojiScale: CGFloat = 1
    /// 本文が絵文字だけのときに、絵文字を大きく描く決まり。nilなら絵文字だけでも大きくしない。
    var emojiOnly: EmojiOnlyEnlargement?
    let emojiImages: EmojiImageStore<UIImage>
    /// 文字列に付ける言語。付けないと、漢字とかなの書体が端末の言語の設定で決まり、英語の設定では日本語も中国語の書体で描かれる。
    let language: String
    /// Unicodeの絵文字を描く絵。描く場所ごとに渡さず、設定から読む。
    var emojiStyle: EmojiStyle = AppDependencies.settings.emojiStyle

    func render(_ text: RichText) -> NSAttributedString {
        if let emojiOnly, let count = text.emojiOnlyCount(isEmoji: { Self.isUnicodeEmoji($0, in: font(for: $1, block: $2)) }) {
            return render(emojiOnlyText: text, count: count, enlargement: emojiOnly)
        }
        let result = NSMutableAttributedString()
        for (index, block) in text.blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let start = result.length
            if let marker = block.listMarker {
                result.append(NSAttributedString(string: marker, attributes: attributes(style: [], block: block)))
            }
            for inline in block.inlines {
                result.append(render(inline, block: block))
            }
            applyParagraphStyle(for: block, to: result, range: NSRange(location: start, length: result.length - start))
        }
        result.separateFallbackSymbols(in: NSRange(location: 0, length: result.length))
        EmojiFont.restoreTextPresentation(in: result)
        return result
    }

    /// 絵文字だけの本文。上限までの数なら、カスタム絵文字と普通の絵文字の割合に同じ倍率を掛けて、普段の釣り合いのまま大きくする。
    /// 先頭のメンションは文字なので、普通の大きさのまま描く。
    /// 大きくしないときも、プレビューで上限の項目を示せるよう、絵文字だけの本文であることを属性に残す。
    private func render(emojiOnlyText text: RichText, count: Int, enlargement: EmojiOnlyEnlargement) -> NSAttributedString {
        var renderer = self
        renderer.emojiOnly = nil
        if count <= enlargement.limit {
            renderer.emojiScale *= enlargement.scale
            renderer.unicodeEmojiScale *= enlargement.scale
        }
        let result = NSMutableAttributedString(attributedString: renderer.render(text))
        result.addAttribute(.emojiOnlyBody, value: true, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// 編集履歴の、前の版との違いを重ねた本文。足した部分は緑の地、消した部分は赤の地で描く。
    /// 色だけに頼らないよう、消した部分には取り消し線も引く。
    /// 地と取り消し線は絵文字の画像の下に描かれ、背景まで塗った不透明な絵文字では隠れるため、足したり消したりした絵文字は、画像そのものの描き方を変える。
    /// 文字を変えずに段落を分けた編集は、ほかに見分ける手がかりがないため、分けた位置に足した改行の記号を置く。
    func render(_ diff: RichTextDiff) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, diffBlock) in diff.blocks.enumerated() {
            let block = RichText.Block(
                inlines: [],
                quoteLevel: diffBlock.quoteLevel,
                isCode: diffBlock.isCode,
                listMarker: diffBlock.listMarker,
                listLevel: diffBlock.listLevel
            )
            if index > 0 {
                if diffBlock.breakChange == .inserted, diffBlock.pieces.first?.change != .inserted {
                    var attributes = attributes(style: [], block: block)
                    attributes.merge(Self.attributes(for: .inserted)) { $1 }
                    result.append(NSAttributedString(string: "↵", attributes: attributes))
                }
                result.append(NSAttributedString(string: "\n"))
            }
            let start = result.length
            if let marker = block.listMarker {
                result.append(NSAttributedString(string: marker, attributes: attributes(style: [], block: block)))
            }
            for piece in diffBlock.pieces {
                let rendered = NSMutableAttributedString(attributedString: render(piece.inline, block: block))
                rendered.addAttributes(Self.attributes(for: piece.change), range: NSRange(location: 0, length: rendered.length))
                if case .emoji = piece.inline, piece.change != .unchanged {
                    Self.markChangedEmoji(in: rendered, change: piece.change)
                }
                result.append(rendered)
            }
            applyParagraphStyle(for: block, to: result, range: NSRange(location: start, length: result.length - start))
        }
        result.separateFallbackSymbols(in: NSRange(location: 0, length: result.length))
        EmojiFont.restoreTextPresentation(in: result)
        return result
    }

    /// 足した部分の地の色。
    private static let insertedTint = UIColor.systemGreen.withAlphaComponent(0.25)

    /// 差分の変わり方ごとに、文字に重ねる見た目。
    static func attributes(for change: DiffChange) -> [NSAttributedString.Key: Any] {
        switch change {
        case .unchanged:
            [:]
        case .inserted:
            [.backgroundColor: insertedTint]
        case .removed:
            [
                .backgroundColor: UIColor.systemRed.withAlphaComponent(0.2),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
    }

    /// 足したり消したりした絵文字の画像に、変わり方に合わせて描き方を変える。
    /// 消した絵文字は薄く描いて、下の赤い地と取り消し線を透かし、動かさない。今の版にない絵文字なので、動かす意味がないため。
    /// 足した絵文字は、地と同じ緑を画像に重ねる。動かすときは、動く層の上にも同じ緑を重ねる（`emojiTint`）。
    private static func markChangedEmoji(in string: NSMutableAttributedString, change: DiffChange) {
        let whole = NSRange(location: 0, length: string.length)
        switch change {
        case .removed: string.removeAttribute(.customEmoji, range: whole)
        case .inserted: string.addAttribute(.emojiTint, value: insertedTint, range: whole)
        case .unchanged: break
        }
        string.enumerateAttribute(.attachment, in: whole) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image, image !== emojiPlaceholder else { return }
            attachment.image = UIGraphicsImageRenderer(size: image.size, format: UIGraphicsImageRendererFormat(for: UITraitCollection(displayScale: image.scale))).image { context in
                let rect = CGRect(origin: .zero, size: image.size)
                switch change {
                case .removed:
                    image.draw(in: rect, blendMode: .normal, alpha: 0.35)
                case .inserted:
                    image.draw(in: rect)
                    insertedTint.setFill()
                    context.fill(rect, blendMode: .sourceAtop)
                case .unchanged:
                    image.draw(in: rect)
                }
            }
        }
    }

    /// 差分を読み上げる文。色と線は読み上げられないため、足した部分と消した部分を言葉で示す。
    static func accessibilityText(of diff: RichTextDiff) -> String {
        var parts: [String] = []
        var run: (change: DiffChange, text: String)?
        func close() {
            guard let run, !run.text.isEmpty else { return }
            switch run.change {
            case .unchanged: parts.append(run.text)
            case .inserted: parts.append("追加：\(run.text)")
            case .removed: parts.append("削除：\(run.text)")
            }
        }
        for (index, block) in diff.blocks.enumerated() {
            if index > 0 {
                // 文字を変えずに段落を分けた位置は、画面の改行の記号と同じく、言葉で示す。
                if block.breakChange == .inserted, block.pieces.first?.change != .inserted {
                    close()
                    run = nil
                    parts.append("追加：段落の区切り")
                } else {
                    run?.text += "\n"
                }
            }
            for piece in block.pieces {
                let text = switch piece.inline {
                case .text(let string, _), .link(let string, _, _): string
                case .emoji(let emoji): ":\(emoji.shortcode):"
                case .lineBreak: "\n"
                }
                if run?.change == piece.change {
                    run?.text += text
                } else {
                    close()
                    run = (piece.change, text)
                }
            }
        }
        close()
        return parts.joined(separator: "、")
    }

    /// 本文中のすべてのカスタム絵文字の、表示に使うURL。
    static func emojiURLs(in text: RichText) -> Set<URL> {
        Set(text.blocks.flatMap(\.inlines).compactMap { inline in
            if case .emoji(let emoji) = inline { emoji.staticUrl } else { nil }
        })
    }

    private func render(_ inline: RichText.Inline, block: RichText.Block) -> NSAttributedString {
        switch inline {
        case .text(let text, let style):
            return NSAttributedString(string: Self.lineSeparated(text), attributes: attributes(style: style, block: block))
        case .link(let text, let destination, let style):
            var attributes = attributes(style: style, block: block)
            attributes[.foregroundColor] = linkColor
            attributes[.linkDestination] = destination
            return NSAttributedString(string: Self.lineSeparated(text), attributes: attributes)
        case .emoji(let emoji):
            return render(emoji, block: block)
        case .lineBreak:
            // 段落を分けると段落間隔が入るため、段落の中の改行は行区切り文字にする。
            return NSAttributedString(string: "\u{2028}", attributes: attributes(style: [], block: block))
        }
    }

    private func render(_ emoji: CustomEmoji, block: RichText.Block) -> NSAttributedString {
        let font = font(for: [], block: block)
        // 先に画像を求める。前に読めなかった画像も、間隔が過ぎていればここで読み直しが始まる。読めるまでは文字で描く。
        let image = emojiImages.image(for: emoji.staticUrl)
        if image == nil, emojiImages.hasFailed(emoji.staticUrl) {
            return NSAttributedString(string: ":\(emoji.shortcode):", attributes: attributes(style: [], block: block))
        }
        // 割合が同じなら、Unicodeの絵文字と同じ高さに描く。
        let height = EmojiFont.glyphHeight(of: font) * emojiScale
        // 絵文字の中心を、和文の字面（em枠）の中心に揃える。文字と大きさが違っても、文字が絵文字の横の真ん中に来るようにするため。
        // 欧文の大文字の中心とも0.03emほどしか違わない。等倍の絵文字は、下端がほぼ文字の下端（descender）に来る。
        let y = Self.emojiCenterHeight * font.pointSize - height / 2
        let attachment = NSTextAttachment()
        if let image, image.size.height > 0 {
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: y, width: height * image.size.width / image.size.height, height: height)
        } else {
            // 読み込み中は同じ高さの空白で場所を取っておく。
            attachment.image = Self.emojiPlaceholder
            attachment.bounds = CGRect(x: 0, y: y, width: height, height: height)
        }
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes(style: [], block: block), range: NSRange(location: 0, length: string.length))
        // アニメーションする絵文字を、描く部品が動かせるよう、どの絵文字かを残す。
        string.addAttribute(.customEmoji, value: emoji, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// コードブロックなどの文字に含まれる改行を、段落を分けない行区切り文字にする。
    private static func lineSeparated(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\u{2028}")
    }

    /// カスタム絵文字の中心の、ベースラインからの高さ（文字の大きさに対する割合）。em枠の中心。
    static let emojiCenterHeight = (PostBodyView.emBoxAscent - PostBodyView.emBoxDescent) / 2

    /// 読み込み中のカスタム絵文字の場所を空けておく、透明な画像。ラベルが、画像が届いて入れ替わったことを見分けるのにも使う。
    static let emojiPlaceholder = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    private func attributes(style: RichText.Style, block: RichText.Block) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style, block: block),
            .foregroundColor: block.quoteLevel > 0 ? secondaryColor : textColor,
            .languageIdentifier: language,
        ]
        if style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private func font(for style: RichText.Style, block: RichText.Block) -> UIFont {
        EmojiFont.font(textFont(for: style, block: block), style: emojiStyle)
    }

    private func textFont(for style: RichText.Style, block: RichText.Block) -> UIFont {
        if block.isCode || style.contains(.code) {
            let weight: UIFont.Weight = style.contains(.bold) ? .bold : .regular
            return UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: font.pointSize, weight: weight))
        }
        var traits = font.fontDescriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        guard traits != font.fontDescriptor.symbolicTraits,
              let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// 段落の絵文字の大きさを変えてから、段落スタイルを付ける。行の高さは、大きさを変えた絵文字から決める。
    private func applyParagraphStyle(for block: RichText.Block, to result: NSMutableAttributedString, range: NSRange) {
        scaleUnicodeEmojis(in: result, range: range)
        var range = range
        // 文字列の最初の文字が、下げて描く絵文字だと、ラベルはその絵文字のずらした位置を最初のベースラインとして報告し、
        // 1行目の上端も絵文字のずらす前の位置から決めるため、本文が上の部品に重なり、絵文字の上が欠ける。
        // 2文字目より後ろや、2行目より後ろの行の先頭ではずれないため、最初の文字だけ、ずらさない幅のない文字を前に置く。
        if range.location == 0, range.length > 0, result.attribute(.scaledUnicodeEmoji, at: 0, effectiveRange: nil) != nil {
            var attributes = attributes(style: [], block: block)
            attributes[.leadingEmojiGuard] = true
            result.insert(NSAttributedString(string: Self.leadingEmojiGuard, attributes: attributes), at: 0)
            range.length += 1
        }
        result.addAttribute(.paragraphStyle, value: paragraphStyle(for: block, emojiExtent: Self.emojiExtent(in: result, range: range)), range: range)
    }

    /// 下げて描く絵文字の前に置く、幅のない文字。コピーするときは取り除く。
    static let leadingEmojiGuard = "\u{200B}"

    /// Unicodeの絵文字を、絵の高さが`unicodeEmojiScale`の割合になる大きさにし、カスタム絵文字と同じく、中心を字面の中心に揃える。
    /// 書体の大きさを割合どおりに変えるだけだと、Appleの絵文字は小さい文字ほど大きめに描くため、1.0から1.1に上げても大きくならず、
    /// 大きくしたときにカスタム絵文字より小さくなる。
    /// 大きさを変えたことを示す属性には、変える前の書体を入れる。絵文字だけの段落でも、余白を文字の書体から測るため。
    private func scaleUnicodeEmojis(in string: NSMutableAttributedString, range: NSRange) {
        guard unicodeEmojiScale != 1 else { return }
        let text = string.string as NSString
        var location = range.location
        while location < NSMaxRange(range) {
            let cluster = text.rangeOfComposedCharacterSequence(at: location)
            location = NSMaxRange(cluster)
            guard let font = string.attribute(.font, at: cluster.location, effectiveRange: nil) as? UIFont,
                  Self.isUnicodeEmoji(text.substring(with: cluster), in: font)
            else { continue }
            let emojiFont = font.withSize(EmojiFont.pointSize(of: font, drawingGlyphsOfHeight: EmojiFont.glyphHeight(of: font) * unicodeEmojiScale))
            string.addAttributes([
                .font: emojiFont,
                // 書体の字面ではなく描く絵の中心を揃える。絵文字の書体は、絵の上に余白を持つため。
                .baselineOffset: Self.emojiCenterHeight * font.pointSize - EmojiFont.glyphBounds(of: emojiFont).midY,
                .scaledUnicodeEmoji: font,
            ], range: cluster)
        }
    }

    /// 書記素クラスタが、絵文字の絵で描かれるか。文字の形で描く指定（U+FE0E）の付いた文字と、キーキャップにならない数字や「#」「*」は除く。
    /// 「❤」や「☺」のように、既定では文字で描く指定の文字も、`font`の書体が持っていなければ、絵文字の書体で描かれるので絵文字とみなす。
    /// 「©」のように`font`の書体が持つ文字は、文字のまま描かれるので除く。
    static func isUnicodeEmoji(_ cluster: String, in font: UIFont) -> Bool {
        let scalars = cluster.unicodeScalars
        guard let first = scalars.first, first.properties.isEmoji, !scalars.contains("\u{FE0E}") else { return false }
        if "0123456789#*".unicodeScalars.contains(first) { return scalars.contains("\u{20E3}") }
        if first.properties.isEmojiPresentation || scalars.count > 1 { return true }
        let characters = Array(String(first).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return !CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count)
    }

    /// 範囲の中の絵文字（カスタム絵文字の画像と、大きさを変えたUnicodeの絵文字）が、ベースラインから上と下へ伸びる長さ。絵文字がなければ0。
    static func emojiExtent(in text: NSAttributedString, range: NSRange) -> (above: CGFloat, below: CGFloat) {
        var above: CGFloat = 0
        var below: CGFloat = 0
        text.enumerateAttribute(.attachment, in: range) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            above = max(above, attachment.bounds.maxY)
            below = max(below, -attachment.bounds.minY)
        }
        // 書体の大きさが違う絵文字が隣り合っても1つずつ測るよう、どの属性が変わってもランを分ける。
        text.enumerateAttributes(in: range) { attributes, run, _ in
            guard attributes[.scaledUnicodeEmoji] != nil, let font = attributes[.font] as? UIFont else { return }
            let offset = attributes[.baselineOffset] as? CGFloat ?? 0
            // 書体のascenderとdescenderではなく、描く絵の枠で測る。書体は絵の上に余白を持つため。
            // 覚える量が絵文字の種類で収まるよう、ランごとではなく絵文字1つずつ測る。
            let string = text.string as NSString
            var location = run.location
            while location < NSMaxRange(run) {
                let cluster = string.rangeOfComposedCharacterSequence(at: location)
                location = NSMaxRange(cluster)
                let glyph = EmojiFont.glyphBounds(of: string.substring(with: cluster), in: font)
                above = max(above, glyph.maxY + offset)
                below = max(below, -(glyph.minY + offset))
            }
        }
        return (above, below)
    }

    /// 1行目の上端から、文字と絵文字の上端までの空き。ふだんは0。
    /// 大きくしたUnicodeの絵文字を下げて描くと、ラベルは下げる前の書体のascenderまでを行の上に取るため、下げた分が1行目の上に空く。
    static func lineTopGap(in text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let paragraph = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        guard let font = textFont(in: text, range: paragraph) else { return 0 }
        let visible = max(font.ascender, emojiExtent(in: text, range: paragraph).above)
        var reserved = visible
        text.enumerateAttributes(in: paragraph) { attributes, _, _ in
            guard attributes[.scaledUnicodeEmoji] != nil, let emojiFont = attributes[.font] as? UIFont else { return }
            reserved = max(reserved, emojiFont.ascender)
        }
        return reserved - visible
    }

    /// 範囲の文字の書体。大きさを変えたUnicodeの絵文字は、大きさを変える前の書体にする。`fromEnd`なら最後の文字の書体。
    static func textFont(in text: NSAttributedString, range: NSRange, fromEnd: Bool = false) -> UIFont? {
        guard range.length > 0 else { return nil }
        let attributes = text.attributes(at: fromEnd ? NSMaxRange(range) - 1 : range.location, effectiveRange: nil)
        return attributes[.scaledUnicodeEmoji] as? UIFont ?? attributes[.font] as? UIFont
    }

    private func paragraphStyle(for block: RichText.Block, emojiExtent: (above: CGFloat, below: CGFloat) = (0, 0)) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = paragraphSpacing
        style.lineSpacing = lineSpacing
        // 絵文字が文字の行より上へ伸びる段落は、行の高さを、絵文字の上端から文字の下端（descent）までにする。
        // 指定しないと、UILabelが見積もる高さより描く行が高くなり、ラベルが文字を縦の中央に寄せて、1行目が上の部品に重なる。
        // ラベルは、この高さから文字のdescentを引いた位置にベースラインを置き、絵文字が文字のdescentより下へ伸びる分は、行の下に自分で足す。
        // 下へ伸びる分までこの高さに含めると、その分が行の上に空く。
        let height = max(font.ascender, emojiExtent.above) - font.descender
        if height > font.lineHeight + 0.5 {
            style.minimumLineHeight = ceil(height)
        }
        let indent = CGFloat(block.quoteLevel + max(0, block.listLevel - 1)) * indentPerLevel
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        if let marker = block.listMarker {
            // 折り返した行を、記号のあとの本文の位置に揃える。
            style.headIndent = indent + (marker as NSString).size(withAttributes: [.font: font]).width
        }
        return style
    }
}

extension NSAttributedString.Key {
    /// リンクの行き先（`RichText.LinkDestination`）。`.link`はUILabelが特別に扱い、再利用したラベルで前の内容の色のまま次の本文を描くことがあるため、
    /// UILabelが関知しない独自の名前で持つ。押されたリンクは`LinkLabel`がこの属性から読む。
    static let linkDestination = NSAttributedString.Key("net.mizle.scia.linkDestination")
    /// 画像を埋め込んだカスタム絵文字（`CustomEmoji`）。`LinkLabel`が、アニメーションする絵文字を動かすのに読む。
    static let customEmoji = NSAttributedString.Key("net.mizle.scia.customEmoji")
    /// カスタム絵文字を動かすときに、動く層の上に重ねる色（`UIColor`）。編集履歴で足した絵文字を示すのに使う。
    static let emojiTint = NSAttributedString.Key("net.mizle.scia.emojiTint")
    /// 下げて描く絵文字の前に置いた、幅のない文字（`RichTextRenderer.leadingEmojiGuard`）。
    static let leadingEmojiGuard = NSAttributedString.Key("net.mizle.scia.leadingEmojiGuard")
    /// 大きさを変えたUnicodeの絵文字の、大きさを変える前の書体（`UIFont`）。行の高さと、本文の上下の余白を測るときに、文字の書体と見分けるのに使う。
    static let scaledUnicodeEmoji = NSAttributedString.Key("net.mizle.scia.scaledUnicodeEmoji")
    /// 絵文字だけの本文（`RichText.emojiOnlyCount`）。プレビューで、絵文字だけの本文の項目を示すのに使う。
    static let emojiOnlyBody = NSAttributedString.Key("net.mizle.scia.emojiOnlyBody")
}

/// 絵文字だけの本文の絵文字を大きく描く決まり。
struct EmojiOnlyEnlargement {
    /// 本文の絵文字の割合に掛ける倍率。
    var scale: CGFloat
    /// 大きくする絵文字の数の上限。
    var limit: Int
}
