import Foundation

/// 投稿本文のHTMLをRichTextに変換する。
/// 対象はMastodonのサニタイザーが残す要素（p、br、a、span、del、pre、code、em、strong、b、i、u、ul、ol、li、blockquote）。
/// それ以外の要素はタグを無視して中の文字だけを残す。
/// https://docs.joinmastodon.org/spec/activitypub/#sanitization
public struct MastodonHTMLParser {
    private let mentions: [Mention]
    private let tagNames: Set<String>
    private let emojiSplitter: CustomEmojiSplitter

    /// `tags`は投稿のタグ。`class`も`rel`もないハッシュタグを、リンクの文字列で見分けるのに使う。
    public init(mentions: [Mention], tags: [Tag], emojis: [CustomEmoji]) {
        self.mentions = mentions
        tagNames = Hashtag.normalizedNames(of: tags)
        emojiSplitter = CustomEmojiSplitter(emojis: emojis)
    }

    public func parse(_ html: String) -> RichText {
        var builder = Builder(mentions: mentions, tagNames: tagNames, emojiSplitter: emojiSplitter)
        for token in HTMLTokenizer.tokenize(html) {
            builder.handle(token)
        }
        return builder.finish()
    }
}

private struct Builder {
    private struct ListContext {
        let isOrdered: Bool
        let isReversed: Bool
        var next: Int
    }

    private struct LinkContext {
        let href: String
        let classes: Set<String>
        let rels: Set<String>
        /// リンクの中の文字を、書式ごとのまとまりで持つ。
        var runs: [(text: String, style: RichText.Style)] = []

        var text: String { runs.map(\.text).joined() }

        mutating func append(_ text: String, style: RichText.Style) {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append((text, style))
            }
        }
    }

    private enum SpanKind {
        case plain
        /// URLの表示で省かれる部分。
        case invisible
        /// URLの表示で省略された部分。閉じたところに「…」を付ける。
        case ellipsis
    }

    let mentions: [Mention]
    let tagNames: Set<String>
    let emojiSplitter: CustomEmojiSplitter

    private var blocks: [RichText.Block] = []
    private var inlines: [RichText.Inline] = []
    private var styleCounts: [RichText.Style: Int] = [:]
    private var quoteLevel = 0
    private var preDepth = 0
    private var lists: [ListContext] = []
    private var listMarker: String?
    private var link: LinkContext?
    private var spans: [SpanKind] = []

    init(mentions: [Mention], tagNames: Set<String>, emojiSplitter: CustomEmojiSplitter) {
        self.mentions = mentions
        self.tagNames = tagNames
        self.emojiSplitter = emojiSplitter
    }

    mutating func finish() -> RichText {
        if let link {
            // 閉じていないリンクは文字として残す。
            self.link = nil
            for run in link.runs {
                appendText(run.text, style: run.style)
            }
        }
        flush()
        return RichText(blocks: blocks)
    }

    mutating func handle(_ token: HTMLToken) {
        switch token {
        case .text(let raw):
            appendRawText(raw)
        case .open(let name, let attributes):
            open(name, attributes: attributes)
        case .close(let name):
            close(name)
        }
    }

    private var currentStyle: RichText.Style {
        styleCounts.reduce(into: RichText.Style()) { style, entry in
            if entry.value > 0 { style.insert(entry.key) }
        }
    }

    private var isHidden: Bool { spans.contains(.invisible) }

    private static func style(for tag: String) -> RichText.Style? {
        switch tag {
        case "b", "strong": .bold
        case "i", "em": .italic
        case "del", "s": .strikethrough
        case "u": .underline
        case "code": .code
        default: nil
        }
    }

    private mutating func open(_ name: String, attributes: [String: String]) {
        switch name {
        case "p":
            flush()
        case "br":
            let style = currentStyle
            if link != nil {
                link?.append("\n", style: style)
            } else if preDepth > 0 {
                appendText("\n", style: currentStyle)
            } else {
                inlines.append(.lineBreak)
            }
        case "blockquote":
            flush()
            quoteLevel += 1
        case "pre":
            flush()
            preDepth += 1
        case "ul", "ol":
            flush()
            let isReversed = attributes["reversed"] != nil
            let start = attributes["start"].flatMap { Int($0) } ?? 1
            lists.append(ListContext(isOrdered: name == "ol", isReversed: isReversed, next: start))
        case "li":
            flush()
            guard var list = lists.popLast() else { break }
            if list.isOrdered {
                let number = attributes["value"].flatMap { Int($0) } ?? list.next
                listMarker = "\(number). "
                // 番号はほかのサーバーの利用者が書いた値で、Mastodonは範囲を確かめずに通す。端を越える先は端の番号のままにする。
                let (next, overflowed) = number.addingReportingOverflow(list.isReversed ? -1 : 1)
                list.next = overflowed ? number : next
            } else {
                listMarker = "• "
            }
            lists.append(list)
        case "a":
            let classes = Set((attributes["class"] ?? "").split(separator: " ").map(String.init))
            let rels = Set((attributes["rel"] ?? "").split(separator: " ").map(String.init))
            link = LinkContext(href: attributes["href"] ?? "", classes: classes, rels: rels)
        case "span":
            let classes = Set((attributes["class"] ?? "").split(separator: " "))
            spans.append(classes.contains("invisible") ? .invisible : classes.contains("ellipsis") ? .ellipsis : .plain)
        default:
            // <pre>の中の<code>は、ブロック全体が等幅になるので書式として数えない。
            if let style = Self.style(for: name), !(name == "code" && preDepth > 0) {
                styleCounts[style, default: 0] += 1
            }
        }
    }

    private mutating func close(_ name: String) {
        switch name {
        case "p":
            flush()
        case "li":
            flush(keepsEmptyListItem: true)
        case "blockquote":
            flush()
            quoteLevel = max(0, quoteLevel - 1)
        case "pre":
            flush()
            preDepth = max(0, preDepth - 1)
        case "ul", "ol":
            flush()
            _ = lists.popLast()
        case "a":
            closeLink()
        case "span":
            if spans.popLast() == .ellipsis, !isHidden {
                appendDisplayedText("…")
            }
        default:
            if let style = Self.style(for: name), !(name == "code" && preDepth > 0), let count = styleCounts[style], count > 0 {
                styleCounts[style] = count - 1
            }
        }
    }

    private mutating func closeLink() {
        guard let link else { return }
        self.link = nil
        let text = link.text
        guard let url = URL(string: link.href), url.scheme != nil else {
            for run in link.runs {
                appendText(run.text, style: run.style)
            }
            return
        }
        let destination: RichText.LinkDestination
        if link.classes.contains("hashtag") || link.rels.contains("tag") || Hashtag.isTagText(text, normalizedNames: tagNames) {
            destination = .hashtag(name: Hashtag.name(ofTagText: text), url: url)
        } else if link.classes.contains("mention") {
            let acct = mentions.first { $0.url == url }?.acct ?? String(text.drop { $0 == "@" })
            destination = .mention(acct: acct, url: url)
        } else {
            destination = .url(url)
        }
        for run in link.runs {
            inlines.append(.link(run.text, destination, run.style))
        }
    }

    private mutating func appendRawText(_ raw: Substring) {
        guard !isHidden else { return }
        let decoded = HTMLEntities.decode(raw)
        appendDisplayedText(preDepth > 0 ? decoded : Self.collapseWhitespace(decoded))
    }

    private mutating func appendDisplayedText(_ text: String) {
        let style = currentStyle
        if link != nil {
            link?.append(text, style: style)
        } else {
            appendText(text, style: currentStyle)
        }
    }

    private mutating func appendText(_ text: String, style: RichText.Style) {
        guard !text.isEmpty else { return }
        if case .text(let previous, let previousStyle) = inlines.last, previousStyle == style {
            inlines[inlines.count - 1] = .text(previous + text, style)
        } else {
            inlines.append(.text(text, style))
        }
    }

    /// HTMLで1つにまとめる空白。全角スペースなどはここに含めず、そのまま残す。
    private static let collapsibleWhitespace: Set<Character> = [" ", "\t", "\n", "\r", "\r\n", "\u{0C}"]

    /// ブラウザと同じく、<pre>の外では連続する空白と改行を1つの空白にまとめる。
    private static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if collapsibleWhitespace.contains(character) {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }

    /// 溜めたインラインをブロックにする。
    /// 本文のないリスト項目は、`<li><p>本文</p></li>`のように項目の中の段落が記号を受け取れるよう、
    /// `keepsEmptyListItem`のとき（項目を閉じるとき）だけ記号だけのブロックとして出す。
    private mutating func flush(keepsEmptyListItem: Bool = false) {
        var content = preDepth > 0 ? inlines : Self.trimmed(inlines)
        content = content.flatMap(emojiSplitter.split)
        if content.isEmpty, listMarker != nil, !keepsEmptyListItem {
            return
        }
        if !content.isEmpty || listMarker != nil {
            blocks.append(RichText.Block(
                inlines: content,
                quoteLevel: quoteLevel,
                isCode: preDepth > 0,
                listMarker: listMarker,
                listLevel: lists.count
            ))
        }
        inlines = []
        listMarker = nil
    }

    /// ブロックの先頭と末尾の空白、改行をのぞく。
    private static func trimmed(_ inlines: [RichText.Inline]) -> [RichText.Inline] {
        var result = inlines
        while let first = result.first {
            if case .lineBreak = first {
                result.removeFirst()
            } else if case .text(let text, let style) = first {
                let trimmed = String(text.drop { $0 == " " })
                if trimmed.isEmpty { result.removeFirst() } else { result[0] = .text(trimmed, style); break }
            } else {
                break
            }
        }
        while let last = result.last {
            if case .lineBreak = last {
                result.removeLast()
            } else if case .text(let text, let style) = last {
                let trimmed = String(text.reversed().drop { $0 == " " }.reversed())
                if trimmed.isEmpty { result.removeLast() } else { result[result.count - 1] = .text(trimmed, style); break }
            } else {
                break
            }
        }
        return result
    }
}
