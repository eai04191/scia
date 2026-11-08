/// 翻訳器へ渡す、また翻訳器から受け取る、段落の部品。
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

    private let richText: RichText
    /// `paragraphs`のそれぞれが、`richText`の何番目の段落か。
    private let blockIndices: [Int]
    private let preserved: [Int: RichText.Inline]

    /// 訳す段落がなければnil。
    init?(_ richText: RichText) {
        var paragraphs: [[TranslationPart]] = []
        var blockIndices: [Int] = []
        var preserved: [Int: RichText.Inline] = [:]
        for (index, block) in richText.blocks.enumerated() where !block.isCode {
            var parts: [TranslationPart] = []
            var blockPreserved: [Int: RichText.Inline] = [:]
            func preserve(_ text: String, _ inline: RichText.Inline) {
                let id = preserved.count + blockPreserved.count
                blockPreserved[id] = inline
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
                case .link(let text, _, _, _): preserve(text, inline)
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
        }
        guard !paragraphs.isEmpty else { return nil }
        self.paragraphs = paragraphs
        self.blockIndices = blockIndices
        self.preserved = preserved
        self.richText = richText
    }

    /// 訳文を当てた本文を返す。`translated`は`paragraphs`と同じ順と数。残す部分が欠けたり増えたりしていれば投げる。
    func applying(_ translated: [[TranslationPart]]) throws -> RichText {
        guard translated.count == paragraphs.count else { throw StatusTranslationError.preservedPartsChanged }
        var result = richText
        for (position, blockIndex) in blockIndices.enumerated() {
            let expected = paragraphs[position].compactMap(Self.preservedID)
            guard translated[position].compactMap(Self.preservedID).sorted() == expected.sorted() else {
                throw StatusTranslationError.preservedPartsChanged
            }
            result.blocks[blockIndex].inlines = inlines(from: translated[position])
        }
        return result
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
                // 翻訳器は、残す部分の文字の端に、訳文との境目の空白を含めて返すことがある。部分そのものは元のものに戻し、空白だけを受け取る。
                builder.append(text: String(text.prefix(while: \.isWhitespace)))
                if let inline = preserved[id] {
                    builder.append(inline)
                }
                if text.contains(where: { !$0.isWhitespace }) {
                    builder.append(text: String(text.reversed().prefix(while: \.isWhitespace).reversed()))
                }
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
        if case .text(let last, let style)? = inlines.last {
            inlines[inlines.count - 1] = .text(last + line, style)
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
