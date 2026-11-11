/// Translationフレームワークへ渡す、またTranslationフレームワークから受け取る、段落の部品。
public enum TranslationPart: Hashable, Sendable {
    case text(String)
    /// 訳さずに残す部分。`id`で、訳文の中のどの部分が元のどれかを見分ける。受け取るときの文字には、前後に空白が付くことがある。
    case preserved(String, id: Int)
}

public enum StatusTranslationError: Error, Equatable {
    /// 翻訳の言語モデルが入っていない。
    case notInstalled
    /// 残すはずの部分が訳文から欠けたか、増えた。
    case preservedPartsChanged
}

/// `RichText`を段落ごとの翻訳の部品に分け、訳文から`RichText`に戻す。決まりはdocs/auto-translation.mdの「本文の扱い」にある。
struct RichTextTranslationPlan: Sendable {
    /// 訳す段落の部品。
    let paragraphs: [[TranslationPart]]
    /// 訳を併記するハッシュタグの、`#`を除いた名前。出てくる順で、同じ名前は1回だけ。
    let hashtags: [String]

    private let richText: RichText
    /// `paragraphs`のそれぞれが、`richText`の何番目の段落か。
    private let blockIndices: [Int]
    private let preserved: [Int: RichText.Inline]
    /// Translationフレームワークへ渡した、残す部分の文字。
    private let originalTexts: [Int: String]

    /// 訳す段落もハッシュタグもなければnil。
    init?(_ richText: RichText) {
        var hashtags: [String] = []
        var paragraphs: [[TranslationPart]] = []
        var blockIndices: [Int] = []
        var preserved: [Int: RichText.Inline] = [:]
        var originalTexts: [Int: String] = [:]
        for (index, block) in richText.blocks.enumerated() where !block.isCode {
            var parts: [TranslationPart] = []
            var blockPreserved: [Int: RichText.Inline] = [:]
            var blockTexts: [Int: String] = [:]
            func preserve(_ text: String, _ inline: RichText.Inline) {
                let id = preserved.count + blockPreserved.count
                blockPreserved[id] = inline
                blockTexts[id] = text
                parts.append(.preserved(text, id: id))
            }
            func appendText(_ text: String) {
                if case .text(let last)? = parts.last {
                    parts[parts.count - 1] = .text(last + text)
                } else {
                    parts.append(.text(text))
                }
            }
            for inline in block.inlines {
                switch inline {
                case .text(let text, let style) where style.contains(.code): preserve(text, inline)
                case .text(let text, _): appendText(text)
                case .link(let text, let destination, let style, _):
                    if case .hashtag(let name, _) = destination, !style.contains(.code), !hashtags.contains(name) { hashtags.append(name) }
                    preserve(text, inline)
                case .emoji(let emoji): preserve(":\(emoji.shortcode):", inline)
                case .lineBreak: appendText("\n")
                }
            }
            let hasWords = parts.contains { part in
                if case .text(let text) = part { text.contains(where: \.isLetter) } else { false }
            }
            guard hasWords else { continue }
            paragraphs.append(parts)
            blockIndices.append(index)
            preserved.merge(blockPreserved) { first, _ in first }
            originalTexts.merge(blockTexts) { first, _ in first }
        }
        guard !paragraphs.isEmpty || !hashtags.isEmpty else { return nil }
        self.paragraphs = paragraphs
        self.hashtags = hashtags
        self.blockIndices = blockIndices
        self.preserved = preserved
        self.originalTexts = originalTexts
        self.richText = richText
    }

    /// 訳文を当てた本文を返す。`translated`は`paragraphs`と同じ順と数。残す部分が欠けたり増えたりしていれば投げる。
    /// `hashtagSuffixes`は、ハッシュタグの名前ごとの、後ろに併記する文字。
    func applying(_ translated: [[TranslationPart]], hashtagSuffixes: [String: String] = [:]) throws -> RichText {
        guard translated.count == paragraphs.count else { throw StatusTranslationError.preservedPartsChanged }
        var result = richText
        // Translationフレームワークへ渡さない段落は、すべて原文のまま残る。
        for index in result.blocks.indices where !blockIndices.contains(index) {
            result.blocks[index].inlines = result.blocks[index].inlines.map(Self.markingOriginal)
        }
        for (position, blockIndex) in blockIndices.enumerated() {
            let expected = paragraphs[position].compactMap(Self.preservedID)
            guard translated[position].compactMap(Self.preservedID).sorted() == expected.sorted() else {
                throw StatusTranslationError.preservedPartsChanged
            }
            result.blocks[blockIndex].inlines = inlines(from: translated[position])
        }
        guard !hashtagSuffixes.isEmpty else { return result }
        for index in result.blocks.indices where !result.blocks[index].isCode {
            result.blocks[index].inlines = Self.appendingSuffixes(hashtagSuffixes, to: result.blocks[index].inlines)
        }
        return result
    }

    /// 併記する訳を、ハッシュタグの後ろに、同じ開く先の別のインラインで足す。訳は原文ではないので、翻訳先の言語の字形で描かせるため。
    /// 書式で分かれた1つのハッシュタグには、最後のインラインの後ろにだけ足す。インラインのコードの中のハッシュタグには足さない。
    private static func appendingSuffixes(_ suffixes: [String: String], to inlines: [RichText.Inline]) -> [RichText.Inline] {
        inlines.indices.flatMap { index -> [RichText.Inline] in
            guard case .link(_, .hashtag(let name, let url), let style, _) = inlines[index], !style.contains(.code), let suffix = suffixes[name] else { return [inlines[index]] }
            if index + 1 < inlines.count, case .link(_, .hashtag(name, url), _, _) = inlines[index + 1] { return [inlines[index]] }
            return [inlines[index], .link(suffix, .hashtag(name: name, url: url), style.subtracting(.original))]
        }
    }

    private static func markingOriginal(_ inline: RichText.Inline) -> RichText.Inline {
        switch inline {
        case .text(let text, let style): .text(text, style.union(.original))
        case .link(let text, let destination, let style, let copied): .link(text, destination, style.union(.original), copied: copied)
        case .emoji, .lineBreak: inline
        }
    }

    private static func leadingWhitespace(_ text: String) -> Substring {
        text.prefix(while: \.isWhitespace)
    }

    /// 文字がすべて空白なら、`leadingWhitespace`と二重に数えないよう、空にする。
    private static func trailingWhitespace(_ text: String) -> Substring {
        guard text.contains(where: { !$0.isWhitespace }) else { return "" }
        return text[text.index(after: text.lastIndex(where: { !$0.isWhitespace }) ?? text.startIndex)...]
    }

    private static func preservedID(_ part: TranslationPart) -> Int? {
        if case .preserved(_, let id) = part { id } else { nil }
    }

    private func inlines(from parts: [TranslationPart]) -> [RichText.Inline] {
        var builder = InlineBuilder()
        for part in parts {
            switch part {
            case .text(let text):
                builder.append(text: text)
            case .preserved(let text, let id):
                // Translationフレームワークは、残す部分の文字の端に、訳文との境目の空白を足して返すことがある。部分そのものは元のものに戻し、足された空白だけを受け取る。
                let original = originalTexts[id] ?? ""
                builder.append(text: String(Self.leadingWhitespace(text).dropLast(Self.leadingWhitespace(original).count)))
                if let inline = preserved[id] {
                    builder.append(Self.markingOriginal(inline))
                }
                builder.append(text: String(Self.trailingWhitespace(text).dropFirst(Self.trailingWhitespace(original).count)))
            }
        }
        return builder.inlines
    }
}

/// 訳文の文字と残す部分を、インラインに並べる。改行は、続けていくつあっても1つの`lineBreak`にする。
private struct InlineBuilder {
    private(set) var inlines: [RichText.Inline] = []
    private var pendsLineBreak = false

    mutating func append(_ inline: RichText.Inline) {
        flushLineBreak()
        inlines.append(inline)
    }

    mutating func append(text: String) {
        var line = ""
        for character in text {
            if character.isNewline {
                appendLine(line)
                line = ""
                pendsLineBreak = true
            } else {
                line.append(character)
            }
        }
        appendLine(line)
    }

    private mutating func appendLine(_ line: String) {
        guard !line.isEmpty else { return }
        flushLineBreak()
        // 残した部分にはつながない。書式が後ろの訳文に移るため。
        if case .text(let last, [])? = inlines.last {
            inlines[inlines.count - 1] = .text(last + line, [])
        } else {
            inlines.append(.text(line, []))
        }
    }

    private mutating func flushLineBreak() {
        if pendsLineBreak, !inlines.isEmpty {
            inlines.append(.lineBreak)
        }
        pendsLineBreak = false
    }
}
