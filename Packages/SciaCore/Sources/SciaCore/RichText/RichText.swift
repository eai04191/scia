public import Foundation

/// 投稿本文や表示名を、UIに依存しない形で表したもの。表示層がNSAttributedStringなどに変換する。
public struct RichText: Hashable, Sendable {
    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// 段落、引用、コードブロック、リスト項目のまとまり。
    public struct Block: Hashable, Sendable {
        public var inlines: [Inline]
        /// 引用の深さ。0なら引用ではない。
        public var quoteLevel: Int
        /// `<pre>`の中。空白と改行をそのまま保つ。
        public var isCode: Bool
        /// リスト項目の先頭に付ける記号（「• 」「1. 」など）。リスト項目でなければnil。
        public var listMarker: String?
        /// リストの入れ子の深さ。0ならリストではない。
        public var listLevel: Int

        public init(inlines: [Inline], quoteLevel: Int = 0, isCode: Bool = false, listMarker: String? = nil, listLevel: Int = 0) {
            self.inlines = inlines
            self.quoteLevel = quoteLevel
            self.isCode = isCode
            self.listMarker = listMarker
            self.listLevel = listLevel
        }
    }

    public enum Inline: Hashable, Sendable {
        case text(String, Style)
        /// `copied`は、表示する文字の代わりにコピーや共有に渡すリンクの文字。表示する文字と同じならnil。
        case link(String, LinkDestination, Style, copied: CopiedLinkText? = nil)
        case emoji(CustomEmoji)
        /// 段落の中の改行（`<br>`）。
        case lineBreak
    }

    public struct Style: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let strikethrough = Style(rawValue: 1 << 2)
        public static let underline = Style(rawValue: 1 << 3)
        public static let code = Style(rawValue: 1 << 4)
    }

    /// サーバーが縮めて見せるURLの、コピーや共有に渡す元の文字。Mastodonのwebで本文を選んでコピーしたときと同じく、
    /// 隠した先頭のスキームと後ろの部分を入れ、「…」を入れない。
    public struct CopiedLinkText: Hashable, Sendable {
        public let text: String
        /// 本文の中で何番目のリンクか。1つのリンクが書式で分かれたときは、どのインラインも同じ値を持ち、つないで1回だけ入れる。
        /// 隣り合う同じ文字の別のリンクとは、この値で分ける。
        public let index: Int

        public init(text: String, index: Int) {
            self.text = text
            self.index = index
        }
    }

    public enum LinkDestination: Hashable, Sendable {
        case url(URL)
        /// `acct`はローカルならusername、リモートならusername@domain。
        case mention(acct: String, url: URL)
        /// `name`は`#`を除いた名前。
        case hashtag(name: String, url: URL)
        /// 文字のまま書かれたハンドル。プロフィールのURLもIDも分からないので、押してから`acct`（`user@domain`）で探す。
        case handle(acct: String)
    }

    /// 本文の表示する文字だけを、段落を改行でつないで返す。テストやログで使う。
    public var plainText: String {
        joined { inline, _ in
            if case .link(let text, _, _, _) = inline { text } else { nil }
        }
    }

    /// コピーや共有に渡す文字。`plainText`と同じ形で、リンクは`copied`があればその文字にする。書式で分かれた1つのリンクの文字は1回だけ入れる。
    public var copiedText: String {
        joined { inline, previous in
            guard case .link(let text, _, _, let copied) = inline else { return nil }
            guard let copied else { return text }
            if case .link(_, _, _, copied)? = previous { return "" }
            return copied.text
        }
    }

    /// 段落を改行でつなぐ。リンクの文字は、そのインラインと同じ段落の1つ前のインラインから`linkText`で決める。
    private func joined(linkText: (_ inline: Inline, _ previous: Inline?) -> String?) -> String {
        blocks.map { block in
            (block.listMarker ?? "") + block.inlines.indices.map { index in
                let inline = block.inlines[index]
                return switch inline {
                case .text(let text, _): text
                case .link: linkText(inline, index > 0 ? block.inlines[index - 1] : nil) ?? ""
                case .emoji(let emoji): ":\(emoji.shortcode):"
                case .lineBreak: "\n"
                }
            }.joined()
        }.joined(separator: "\n")
    }
}

extension RichText {
    /// HTMLではない文字列（表示名など）を、カスタム絵文字だけ置き換えて1段落にする。
    public static func plain(_ text: String, emojis: [CustomEmoji]) -> RichText {
        RichText(blocks: [Block(inlines: CustomEmojiSplitter(emojis: emojis).split(.text(text, [])))])
    }

    /// プロフィールの自己紹介や補足情報のような、投稿の本文以外のHTML。メンションのリストがないため、メンションはリンクとして読む。
    public static func html(_ html: String, emojis: [CustomEmoji]) -> RichText {
        MastodonHTMLParser(mentions: [], tags: [], emojis: emojis).parse(html)
    }

    /// プロフィールの補足情報のHTML。幅に余裕があるので、サーバーが縮めたURLも全体を出す。
    public static func profileField(_ html: String, emojis: [CustomEmoji]) -> RichText {
        MastodonHTMLParser(mentions: [], tags: [], emojis: emojis, expandsShortenedURLs: true, linksPlainHandles: true).parse(html)
    }

    /// プロフィールの自己紹介のHTML。
    public static func profileNote(_ html: String, emojis: [CustomEmoji]) -> RichText {
        MastodonHTMLParser(mentions: [], tags: [], emojis: emojis, linksPlainHandles: true).parse(html)
    }

    /// 引用のある投稿では、サーバーが互換のために足す`RE: <リンク>`の段落を除く。
    public static func status(_ status: Status) -> RichText {
        MastodonHTMLParser(mentions: status.mentions, tags: status.tags, emojis: status.emojis, dropsQuoteInline: status.quote != nil).parse(status.content)
    }
}

/// 文字列中の`:shortcode:`を、登録されたカスタム絵文字に置き換える。
struct CustomEmojiSplitter {
    private let emojis: [String: CustomEmoji]

    init(emojis: [CustomEmoji]) {
        self.emojis = Dictionary(emojis.map { ($0.shortcode, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func split(_ inline: RichText.Inline) -> [RichText.Inline] {
        guard case .text(let text, let style) = inline, !emojis.isEmpty, text.contains(":") else { return [inline] }
        var result: [RichText.Inline] = []
        var buffer = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(of: ":") {
            let afterColon = rest.index(after: start)
            guard let end = rest[afterColon...].firstIndex(of: ":") else { break }
            let shortcode = String(rest[afterColon..<end])
            if let emoji = emojis[shortcode] {
                buffer += rest[..<start]
                if !buffer.isEmpty { result.append(.text(buffer, style)) }
                buffer = ""
                result.append(.emoji(emoji))
                rest = rest[rest.index(after: end)...]
            } else {
                // 閉じのコロンが次のショートコードの開きになりうるため、閉じの手前までを進める。
                buffer += rest[..<end]
                rest = rest[end...]
            }
        }
        buffer += rest
        if !buffer.isEmpty { result.append(.text(buffer, style)) }
        return result
    }
}

extension RichText {
    /// 段落と改行を詰めて、1つの段落にしたもの。通知で再掲する投稿の本文に使う。決まりはdocs/notification-display.mdの「再掲する投稿の本文」にある。
    /// 境目には空白を1つ置き、境目の前後がもともと空白なら足さない。引用とリストの字下げはせず、リスト項目の記号は文字として残す。
    /// コードブロックの文字とリンクは、改行を空白にし、等幅の書体で描くよう`code`の書式を付ける。
    /// リンクは1つの部品のまま残し、表示する文字の中の改行（`<a>`の中の`<br>`）も空白にする。
    public func joiningLines() -> RichText {
        guard !blocks.isEmpty else { return self }
        var inlines: [Inline] = []
        // 次の部品の前に、境目の空白を置くか。
        var pendsSeparator = false
        func append(_ inline: Inline) {
            if pendsSeparator, let last = inlines.last, !last.endsWithWhitespace, !inline.startsWithWhitespace {
                inlines.append(.text(" ", []))
            }
            pendsSeparator = false
            inlines.append(inline)
        }
        for block in blocks {
            if let marker = block.listMarker {
                append(.text(marker, []))
            }
            for inline in block.inlines {
                switch inline {
                case .lineBreak:
                    pendsSeparator = true
                case .text(let text, let style):
                    // コードブロックの中の改行も、段落の境目と同じく空白にする。
                    for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                        if index > 0 {
                            pendsSeparator = true
                        }
                        if !line.isEmpty {
                            append(.text(String(line), block.isCode ? style.union(.code) : style))
                        }
                    }
                case .link(let text, let destination, let style, let copied):
                    let joined = text.split(whereSeparator: \.isNewline).joined(separator: " ")
                    append(.link(joined, destination, block.isCode ? style.union(.code) : style, copied: copied))
                case .emoji:
                    append(inline)
                }
            }
            pendsSeparator = true
        }
        return RichText(blocks: [Block(inlines: inlines)])
    }
}

private extension RichText.Inline {
    /// 文字とリンクの、表示する文字。
    var displayedText: String? {
        switch self {
        case .text(let text, _), .link(let text, _, _, _): text
        case .emoji, .lineBreak: nil
        }
    }

    var startsWithWhitespace: Bool {
        displayedText?.first?.isWhitespace ?? false
    }

    var endsWithWhitespace: Bool {
        displayedText?.last?.isWhitespace ?? false
    }
}
