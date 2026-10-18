internal import NaturalLanguage

/// 2つの版の本文の違い。新しい版の並びに、前の版から消えた部分を差し込んで並べる。
///
/// 比べる単位は単語にする。文字単位では「14時」を「15時」に直したときに「1」だけが残り、何が何に変わったか読み取りにくいため。
/// 日本語のように空白で区切らない言語も、`NLTokenizer`で単語に分ける。リンク、カスタム絵文字、改行は分けずに1つとして比べる。
public struct RichTextDiff: Equatable, Sendable {
    public var blocks: [Block]

    public struct Block: Equatable, Sendable {
        public var pieces: [Piece]
        public var quoteLevel: Int
        public var isCode: Bool
        public var listMarker: String?
        public var listLevel: Int
        /// この段落の始まりが前の版になかったか、段落の形（引用かどうかなど）が変わったなら`.inserted`。
        /// 文字を変えずに段落を分けた編集や、引用にしただけの編集を見分けるため。
        public var breakChange: DiffChange

        init(pieces: [Piece], layout: Layout, breakChange: DiffChange = .unchanged) {
            self.pieces = pieces
            self.breakChange = breakChange
            quoteLevel = layout.quoteLevel
            isCode = layout.isCode
            listMarker = layout.listMarker
            listLevel = layout.listLevel
        }
    }

    public struct Piece: Equatable, Sendable {
        public var inline: RichText.Inline
        public var change: DiffChange

        public init(_ inline: RichText.Inline, _ change: DiffChange) {
            self.inline = inline
            self.change = change
        }
    }

    /// どこかが足されたか消された。
    public var hasChanges: Bool {
        blocks.contains { $0.breakChange != .unchanged || $0.pieces.contains { $0.change != .unchanged } }
    }

    /// 前の版のない本文。すべて変わらないものとして並べる。
    public init(unchanged text: RichText) {
        blocks = text.blocks.map { block in
            Block(pieces: block.inlines.map { Piece($0, .unchanged) }, layout: Layout(block))
        }
    }

    /// `old`から`new`への違い。
    ///
    /// 変わらない部分の文字数が、長い方の版の文字数の`minimumUnchangedRatio`に満たなければ、書き直したものとして、
    /// 前の版をまるごと消し、新しい版をまるごと足した形にする。大半を書き直した版に細かく重ねると、どちらの版も読めなくなるため。
    /// `language`は単語に分けるときの手がかりで、分からなければnil。
    public init(old: RichText, new: RichText, language: String? = nil, minimumUnchangedRatio: Double) {
        let tokenizer = WordTokenizer(language: language)
        let merged = Self.absorbingSpaces(SequenceDiff.merged(Token.tokens(of: old, tokenizer: tokenizer), Token.tokens(of: new, tokenizer: tokenizer)))
        let unchangedLength = merged.filter { $0.1 == .unchanged }.map(\.0.length).reduce(0, +)
        let longerLength = max(old.length, new.length)
        if longerLength > 0, Double(unchangedLength) < Double(longerLength) * minimumUnchangedRatio {
            blocks = Self.rewritten(old: old, new: new)
        } else {
            blocks = Self.blocks(from: merged)
        }
    }

    /// 変更に挟まれた空白だけの一致を、変更のまとまりに含める。
    /// 英語のように空白で区切る文を書き換えると、単語のあいだの空白だけが一致して「[-a-]{+x+} [-b-]{+y+}」と細切れになるため。
    /// 空白より長い一致はまとめない。「の」のような短い一致までまとめると、文の大半が1つの置き換えになり、どこを直したか分からなくなる。
    static func absorbingSpaces(_ merged: [(Token, DiffChange)]) -> [(Token, DiffChange)] {
        var result: [(Token, DiffChange)] = []
        var removed: [Token] = []
        var inserted: [Token] = []
        var spaces: [Token] = []
        func flush() {
            result += removed.map { ($0, .removed) } + inserted.map { ($0, .inserted) } + spaces.map { ($0, .unchanged) }
            removed = []
            inserted = []
            spaces = []
        }
        for (token, change) in merged {
            switch change {
            case .removed, .inserted:
                if !spaces.isEmpty {
                    removed += spaces
                    inserted += spaces
                    spaces = []
                }
                if change == .removed { removed.append(token) } else { inserted.append(token) }
            case .unchanged:
                if token.isSpace, !(removed.isEmpty && inserted.isEmpty) {
                    spaces.append(token)
                } else {
                    flush()
                    result.append((token, .unchanged))
                }
            }
        }
        flush()
        return result
    }

    private static func rewritten(old: RichText, new: RichText) -> [Block] {
        func blocks(_ text: RichText, _ change: DiffChange) -> [Block] {
            text.blocks.map { Block(pieces: $0.inlines.map { Piece($0, change) }, layout: Layout($0)) }
        }
        return blocks(old, .removed) + blocks(new, .inserted)
    }

    /// 比べた結果を、段落に組み直す。段落は、新しい版にある段落の始まりだけで切る。
    /// 消えた段落の始まりは、同じ変更のまとまりの中で新しい始まりが足されていなければ、消えた改行として残す。
    /// 消えた段落の文字が、前の段落の末尾に続けて並ばないようにするため。
    private static func blocks(from merged: [(Token, DiffChange)]) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        func append(_ inline: RichText.Inline, _ change: DiffChange) {
            if current == nil {
                current = Block(pieces: [], layout: Layout())
            }
            current?.append(Piece(inline, change))
        }
        for (index, (token, change)) in merged.enumerated() {
            switch token {
            case .blockStart(let layout):
                switch change {
                case .unchanged, .inserted:
                    if let current { blocks.append(current) }
                    current = Block(pieces: [], layout: layout, breakChange: change)
                case .removed:
                    // 先頭の段落の始まりが消えたときは、前に文字がないので改行を残さない。
                    if !startsBlock(in: merged, around: index) {
                        current?.append(Piece(.lineBreak, .removed))
                    }
                }
            case .inline(let inline):
                append(inline, change)
            case .link(let inlines):
                inlines.forEach { append($0, change) }
            }
        }
        if let current { blocks.append(current) }
        return blocks
    }

    /// `index`を含む変更のまとまりに、足された段落の始まりがあるか。
    private static func startsBlock(in merged: [(Token, DiffChange)], around index: Int) -> Bool {
        var start = index
        while start > 0, merged[start - 1].1 != .unchanged { start -= 1 }
        var end = index
        while end < merged.count - 1, merged[end + 1].1 != .unchanged { end += 1 }
        return merged[start...end].contains { token, change in
            if case .blockStart = token, change == .inserted { return true }
            return false
        }
    }

    /// 段落の形。段落の区切りどうしを比べるときに使う。
    struct Layout: Equatable {
        var quoteLevel = 0
        var isCode = false
        var listMarker: String?
        var listLevel = 0

        init() {}

        init(_ block: RichText.Block) {
            quoteLevel = block.quoteLevel
            isCode = block.isCode
            listMarker = block.listMarker
            listLevel = block.listLevel
        }
    }

    /// 比べる単位。
    enum Token: Equatable {
        case inline(RichText.Inline)
        /// 行き先の同じリンクの続き。パーサーは書式の違う部分ごとにリンクを分けるが、1つのリンクとして比べる。
        case link([RichText.Inline])
        /// 段落の始まり。先頭の段落にも置き、段落の形（引用かどうかなど）の変更も比べる。
        case blockStart(Layout)

        static func tokens(of text: RichText, tokenizer: WordTokenizer) -> [Token] {
            var tokens: [Token] = []
            for block in text.blocks {
                tokens.append(.blockStart(Layout(block)))
                for inline in block.inlines {
                    switch inline {
                    case .text(let string, let style):
                        tokens += tokenizer.words(in: string).map { .inline(.text($0, style)) }
                    case .link(_, let destination, _):
                        if case .link(let previous)? = tokens.last, case .link(_, let previousDestination, _)? = previous.last,
                           previousDestination == destination {
                            tokens[tokens.count - 1] = .link(previous + [inline])
                        } else {
                            tokens.append(.link([inline]))
                        }
                    case .emoji, .lineBreak:
                        tokens.append(.inline(inline))
                    }
                }
            }
            return tokens
        }

        var isSpace: Bool {
            guard case .inline(.text(let string, _)) = self else { return false }
            return string.allSatisfy(\.isWhitespace)
        }

        /// 書き直したかを決めるときに数える文字数。カスタム絵文字は1文字、区切りは0文字として数える。
        var length: Int {
            switch self {
            case .inline(.text(let string, _)), .inline(.link(let string, _, _)): string.count
            case .link(let inlines): inlines.map { Token.inline($0).length }.reduce(0, +)
            case .inline(.emoji): 1
            case .inline(.lineBreak), .blockStart: 0
            }
        }
    }
}

extension RichTextDiff.Block {
    /// 同じ変わり方で同じ見た目の文字が続いたら、1つにつなぐ。単語に分けたまま描くと、部品が無駄に増えるため。
    mutating func append(_ piece: RichTextDiff.Piece) {
        if let last = pieces.last, last.change == piece.change,
           case .text(let lastText, let lastStyle) = last.inline,
           case .text(let text, let style) = piece.inline, lastStyle == style {
            pieces[pieces.count - 1] = RichTextDiff.Piece(.text(lastText + text, style), piece.change)
        } else {
            pieces.append(piece)
        }
    }
}

extension RichText {
    /// 書き直したかを決めるときに数える文字数。
    var length: Int {
        blocks.flatMap(\.inlines).map { RichTextDiff.Token.inline($0).length }.reduce(0, +)
    }
}

/// 文字列を単語に分ける。単語のあいだの空白や句読点は、1文字ずつに分ける。
struct WordTokenizer {
    let language: String?

    func words(in string: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = string
        if let language {
            tokenizer.setLanguage(NLLanguage(rawValue: language))
        }
        var words: [String] = []
        var end = string.startIndex
        tokenizer.enumerateTokens(in: string.startIndex..<string.endIndex) { range, _ in
            words += string[end..<range.lowerBound].map(String.init)
            words.append(String(string[range]))
            end = range.upperBound
            return true
        }
        words += string[end...].map(String.init)
        return words
    }
}
