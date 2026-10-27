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
        case link(String, LinkDestination, Style)
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

    public enum LinkDestination: Hashable, Sendable {
        case url(URL)
        /// `acct`はローカルならusername、リモートならusername@domain。
        case mention(acct: String, url: URL)
        /// `name`は`#`を除いた名前。
        case hashtag(name: String, url: URL)
    }

    /// 本文の文字だけを、段落を改行でつないで返す。テストやログで使う。
    public var plainText: String {
        blocks.map { block in
            (block.listMarker ?? "") + block.inlines.map { inline in
                switch inline {
                case .text(let text, _), .link(let text, _, _): text
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

    /// 投稿本文のHTMLを、メンション、ハッシュタグ、カスタム絵文字を解決して変換する。
    /// プロフィールの自己紹介や補足情報のような、投稿の本文以外のHTML。メンションの一覧がないため、メンションはリンクとして読む。
    public static func html(_ html: String, emojis: [CustomEmoji]) -> RichText {
        MastodonHTMLParser(mentions: [], tags: [], emojis: emojis).parse(html)
    }

    /// プロフィールの補足情報のHTML。幅に余裕があるので、サーバーが縮めたURLも全体を出す。
    public static func profileField(_ html: String, emojis: [CustomEmoji]) -> RichText {
        MastodonHTMLParser(mentions: [], tags: [], emojis: emojis, expandsShortenedURLs: true).parse(html)
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
