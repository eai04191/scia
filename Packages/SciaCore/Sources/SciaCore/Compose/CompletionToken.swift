/// 投稿欄で補完するものの種類。
public enum CompletionKind: String, Sendable, Hashable, CaseIterable {
    /// `@`か`＠`で始まるメンション。
    case mention
    /// `#`か`＃`で始まるハッシュタグ。
    case hashtag
    /// `:`で始まるカスタム絵文字。
    case emoji
}

/// 補完の対象にする語。位置はUTF-16で数える（`UITextView`の`NSRange`と同じ）。
public struct CompletionToken: Equatable, Hashable, Sendable {
    public let kind: CompletionKind
    /// 置き換える範囲。`@`などの記号から、語の終わりまで（ハッシュタグはカーソルまで）。絵文字で閉じの`:`まで打ってあれば、それも含む。
    public let range: Range<Int>
    /// 記号を除いた語。メンションと絵文字は、カーソルより後ろに続く部分も含む。
    public let query: String
    /// 記号の直前が、サーバーがメンション・タグ・絵文字として読まない文字（日本語の文字など）。選んだら前に空白を入れる。
    public let needsLeadingSpace: Bool

    public init(kind: CompletionKind, range: Range<Int>, query: String, needsLeadingSpace: Bool) {
        self.kind = kind
        self.range = range
        self.query = query
        self.needsLeadingSpace = needsLeadingSpace
    }
}

/// 候補を選んだときに、本文へ入れるもの。
public struct CompletionInsertion: Equatable, Sendable {
    /// 置き換える範囲（UTF-16）。
    public let range: Range<Int>
    public let text: String
    /// 入れたあとのカーソルの位置（UTF-16）。
    public let cursor: Int

    public init(range: Range<Int>, text: String, cursor: Int) {
        self.range = range
        self.text = text
        self.cursor = cursor
    }
}

/// 本文のカーソルの位置から、補完の対象にする語を切り出す。
///
/// どこからを語とみなすかは、サーバーが本文からメンション・タグ・絵文字を読む規則（Mastodonの`Account::MENTION_RE`、`Tag::HASHTAG_RE`、
/// `CustomEmoji::SCAN_RE`）に合わせる。ただし日本語の文字のすぐ後に打った記号は、サーバーは読まないが、空白を入れれば読むので候補を出す。
/// 英数字や`/`の後の記号は、メールアドレス、URL、時刻（`12:30`）の一部なので候補を出さない。
public enum CompletionTokenizer {
    /// 左へたどる文字数の上限。長い本文で、カーソルを動かすたびに先頭まで見ないようにする。
    private static let maxScanLength = 300

    /// - Parameters:
    ///   - selection: 選んでいる範囲（UTF-16）。空でなければ補完しない。
    ///   - markedRange: 変換中の未確定の文字の範囲（UTF-16）。あれば補完しない。確定してから語を読み直す。
    ///   - kinds: 補完する種類。注意書きの欄では絵文字だけにする。
    ///   - minimumQueryLength: 記号のあとに何文字打ったら語にするか。英数字以外は1文字を2文字と数える。ない種類は1文字。0なら記号だけでも語にする。
    public static func token(
        in text: String,
        selection: Range<Int>,
        markedRange: Range<Int>? = nil,
        kinds: Set<CompletionKind> = Set(CompletionKind.allCases),
        minimumQueryLength: [CompletionKind: Int] = [:]
    ) -> CompletionToken? {
        guard selection.isEmpty, markedRange?.isEmpty ?? true else { return nil }
        let characters = IndexedCharacters(text)
        guard let cursor = characters.index(atUTF16: selection.lowerBound) else { return nil }
        let lowerLimit = max(0, cursor - maxScanLength)
        var index = cursor - 1
        while index >= lowerLimit {
            let character = characters[index]
            if character.isWhitespace { return nil }
            if let kind = kind(ofTrigger: character), kinds.contains(kind),
               let token = token(kind: kind, triggerAt: index, cursor: cursor, in: characters, minimumQueryLength: minimumQueryLength[kind] ?? 1) {
                return token
            }
            index -= 1
        }
        return nil
    }

    /// 候補を選んだときに、語と置き換えるもの。語の後ろに空白がなければ空白を足し、続けて書けるようにする。
    /// 空白がすでにあれば足さず、カーソルをその空白の後ろに置く。
    public static func insertion(of completion: String, replacing token: CompletionToken, in text: String) -> CompletionInsertion {
        let replacement = (token.needsLeadingSpace ? " " : "") + completion
        let start = token.range.lowerBound
        let after = String(decoding: Array(text.utf16).dropFirst(token.range.upperBound), as: UTF16.self)
        if let next = after.first, next.isWhitespace, !next.isNewline {
            return CompletionInsertion(range: token.range, text: replacement, cursor: start + replacement.utf16.count + next.utf16.count)
        }
        let inserted = replacement + " "
        return CompletionInsertion(range: token.range, text: inserted, cursor: start + inserted.utf16.count)
    }

    /// 絵文字のパレットで選んだ絵文字を、選んでいる範囲と置き換えて入れるもの。語を打っていないので、前後の文字だけを見て空白を足す。
    /// 直前がサーバーが絵文字として読まない文字（英数字、日本語、`:`）なら前に空白を入れる。後ろは補完と同じく、空白がなければ足す。
    /// 続けて選んでも`:a: :b:`になり、`:a::b:`のようにサーバーが読まない並びにならない。
    public static func insertion(of completion: String, at selection: Range<Int>, in text: String) -> CompletionInsertion {
        let utf16 = Array(text.utf16)
        let lower = min(max(selection.lowerBound, 0), utf16.count)
        let upper = min(max(selection.upperBound, lower), utf16.count)
        let before = String(decoding: utf16.prefix(lower), as: UTF16.self)
        let needsLeadingSpace = !serverAccepts(.emoji, after: before.last)
        return insertion(
            of: completion,
            replacing: CompletionToken(kind: .emoji, range: lower ..< upper, query: "", needsLeadingSpace: needsLeadingSpace),
            in: text
        )
    }

    /// 投稿欄の＋で選んだ`@`か`#`を、選んでいる範囲と置き換えて入れるもの。続けて名前を打つので、後ろに空白は足さない。
    /// 直前の文字のままではサーバーがメンションやタグとして読まないなら、前に空白を入れる。英数字の直後でも、空白を入れれば補完が出る。
    public static func insertion(ofMark kind: CompletionKind, at selection: Range<Int>, in text: String) -> CompletionInsertion {
        let utf16 = Array(text.utf16)
        let lower = min(max(selection.lowerBound, 0), utf16.count)
        let upper = min(max(selection.upperBound, lower), utf16.count)
        let before = String(decoding: utf16.prefix(lower), as: UTF16.self)
        let mark = switch kind {
        case .mention: "@"
        case .hashtag: "#"
        case .emoji: ":"
        }
        let inserted = (serverAccepts(kind, after: before.last) ? "" : " ") + mark
        return CompletionInsertion(range: lower ..< upper, text: inserted, cursor: lower + inserted.utf16.count)
    }

    /// 絵文字のパレットの削除キーで消す範囲。カーソルの直前が`:shortcode:`（パレットが足した後ろの空白を含む）なら、まとめて消す。
    /// 1文字ずつ消すと、絵文字1つに何度も押すことになるため。それ以外と、範囲を選んでいるときはnilを返し、ふつうに1文字消す。
    public static func emojiDeletionRange(before selection: Range<Int>, in text: String) -> Range<Int>? {
        guard selection.isEmpty else { return nil }
        let utf16 = Array(text.utf16)
        guard selection.lowerBound <= utf16.count else { return nil }
        let before = String(decoding: utf16.prefix(selection.lowerBound), as: UTF16.self)
        guard let match = before.firstMatch(of: /:[A-Za-z0-9_]{2,}: ?$/) else { return nil }
        let length = before[match.range].utf16.count
        return selection.lowerBound - length ..< selection.lowerBound
    }

    private static func kind(ofTrigger character: Character) -> CompletionKind? {
        switch character {
        case "@", "＠": .mention
        case "#", "＃": .hashtag
        case ":": .emoji
        default: nil
        }
    }

    private static func token(kind: CompletionKind, triggerAt trigger: Int, cursor: Int, in characters: IndexedCharacters, minimumQueryLength: Int) -> CompletionToken? {
        switch kind {
        case .mention:
            mentionToken(triggerAt: trigger, cursor: cursor, in: characters, minimumQueryLength: minimumQueryLength)
        case .hashtag, .emoji:
            simpleToken(kind: kind, triggerAt: trigger, cursor: cursor, in: characters, minimumQueryLength: minimumQueryLength)
        }
    }

    /// `@user`か`@user@domain`。ドメインの`@`の上にカーソルがあるときは、その前の`@`を先頭の記号にする。
    private static func mentionToken(triggerAt at: Int, cursor: Int, in characters: IndexedCharacters, minimumQueryLength: Int) -> CompletionToken? {
        var trigger = at
        // `@user@dom`の2つ目の`@`から左に、ユーザー名と1つ目の`@`が続いていれば、1つ目を先頭の記号にする。
        var start = at - 1
        while start >= 0, isUsernameCharacter(characters[start]) {
            start -= 1
        }
        if start >= 0, start < at - 1, kind(ofTrigger: characters[start]) == .mention {
            trigger = start
        }
        let typed = characters.string(trigger + 1 ..< cursor)
        guard isMentionQuery(typed) else { return nil }
        // 語の残りは、ドメインまで打っていればドメインの文字、まだならユーザー名の文字で続ける。
        let hasDomain = typed.contains("@")
        let continues = { (character: Character) in hasDomain ? isDomainCharacter(character) : isUsernameCharacter(character) }
        var end = cursor
        while end < characters.count, continues(characters[end]) {
            end += 1
        }
        // ユーザー名の途中を書き直しているときは、後ろに続くドメインも語に含める。含めないと、選んだときに元のドメインが残る。
        if !hasDomain, end + 1 < characters.count, characters[end] == "@", isDomainCharacter(characters[end + 1]) {
            end += 1
            while end < characters.count, isDomainCharacter(characters[end]) {
                end += 1
            }
        }
        // カーソルより後ろの末尾の`.`や`-`は文の句読点とみなし、語に含めない。サーバーの`MENTION_RE`も末尾には含めない。
        while end > cursor, characters[end - 1] == "." || characters[end - 1] == "-" {
            end -= 1
        }
        let query = characters.string(trigger + 1 ..< end)
        // 記号だけなら空の語にする。文字数の下限で出すかを決める。
        if let first = query.first, !isUsernameStart(first) { return nil }
        return makeToken(kind: .mention, trigger: trigger, end: end, query: query, in: characters, minimumQueryLength: minimumQueryLength)
    }

    private static func simpleToken(kind: CompletionKind, triggerAt trigger: Int, cursor: Int, in characters: IndexedCharacters, minimumQueryLength: Int) -> CompletionToken? {
        let isQueryCharacter = { (character: Character) in kind == .hashtag ? isHashtagCharacter(character) : isShortcodeCharacter(character) }
        guard characters.string(trigger + 1 ..< cursor).allSatisfy(isQueryCharacter) else { return nil }
        var end = cursor
        // ハッシュタグは日本語の文が空白なしで続くことがあり、語の終わりが分からないので、カーソルの後ろは語に含めない。
        // 含めると、タグの途中で選んだときに、後ろに続く文まで置き換えて消してしまう。
        while kind == .emoji, end < characters.count, isQueryCharacter(characters[end]) {
            end += 1
        }
        let query = characters.string(trigger + 1 ..< end)
        // 閉じの`:`まで打ってあれば、置き換える範囲に含めて二重にしない。
        if kind == .emoji, end < characters.count, characters[end] == ":" {
            end += 1
        }
        return makeToken(kind: kind, trigger: trigger, end: end, query: query, in: characters, minimumQueryLength: minimumQueryLength)
    }

    private static func makeToken(kind: CompletionKind, trigger: Int, end: Int, query: String, in characters: IndexedCharacters, minimumQueryLength: Int) -> CompletionToken? {
        guard queryLength(query) >= minimumQueryLength else { return nil }
        let previous = trigger > 0 ? characters[trigger - 1] : nil
        guard !suppressesCompletion(after: previous) else { return nil }
        let accepts = serverAccepts(kind, after: previous)
        return CompletionToken(
            kind: kind,
            range: characters.utf16Offset(of: trigger) ..< characters.utf16Offset(of: end),
            query: query,
            needsLeadingSpace: !accepts
        )
    }

    /// 打った文字数。英数字は1文字、日本語などは2文字と数える。漢字1文字（`#猫`）でも意味のあるタグになり、
    /// 英数字の2文字と同じくらい候補を絞れるため。
    static func queryLength(_ query: String) -> Int {
        query.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    }

    /// 記号の直前の文字のままで、サーバーがメンション・タグ・絵文字として読むか。
    private static func serverAccepts(_ kind: CompletionKind, after previous: Character?) -> Bool {
        guard let previous else { return true }
        switch kind {
        case .mention:
            // `(?<![=/[:word:]])@`
            return !(isWordCharacter(previous) || previous == "=" || previous == "/")
        case .hashtag:
            // `(?<=^|[[:space:]])[#＃]`
            return previous.isWhitespace
        case .emoji:
            // `(?<=[^[:alnum:]:]|\n|^):`
            return previous.isNewline || !(previous.isLetter || previous.isNumber || previous == ":")
        }
    }

    /// 英数字や`/`の後の記号は、メールアドレス、URL、時刻の一部とみなし、空白を入れて補完することもしない。
    private static func suppressesCompletion(after previous: Character?) -> Bool {
        guard let previous, previous.isASCII else { return false }
        return previous.isLetter || previous.isNumber || previous == "_" || previous == "/" || previous == "="
    }

    /// Rubyの`[[:word:]]`。文字、結合文字、数字、接続符号。
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
            || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .connectorPunctuation }
    }

    /// 打っている途中のメンション。`user`、`user.`、`user@`、`user@dom.ain`を認める。
    private static func isMentionQuery(_ typed: String) -> Bool {
        let parts = typed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts[0].allSatisfy(isUsernameCharacter) else { return false }
        return parts.count == 1 || parts[1].allSatisfy(isDomainCharacter)
    }

    /// Mastodonのユーザー名は`[a-z0-9_]+([.-]+[a-z0-9_]+)*`で、英数字の大文字小文字を区別しない。
    private static func isUsernameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "." || character == "-")
    }

    private static func isUsernameStart(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    /// ドメインは`[[:word:]]+([.-]+[[:word:]]+)*`。国際化ドメインの文字も含む。
    private static func isDomainCharacter(_ character: Character) -> Bool {
        isWordCharacter(character) || character == "." || character == "-"
    }

    /// ハッシュタグの名前に使える文字。Mastodonの`HASHTAG_SEPARATORS`（`_`、`·`、`・`、ZWNJ）を含む。
    private static func isHashtagCharacter(_ character: Character) -> Bool {
        isWordCharacter(character) || character == "·" || character == "・" || character == "\u{200C}"
    }

    /// カスタム絵文字のショートコードは`[a-zA-Z0-9_]`。
    private static func isShortcodeCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }
}

/// 文字（書記素）の並びと、それぞれのUTF-16での位置。
private struct IndexedCharacters {
    private let characters: [Character]
    /// `characters[i]`が始まるUTF-16の位置。最後に全体の長さを足す。
    private let offsets: [Int]

    init(_ text: String) {
        var characters: [Character] = []
        var offsets: [Int] = []
        var offset = 0
        for character in text {
            characters.append(character)
            offsets.append(offset)
            offset += character.utf16.count
        }
        offsets.append(offset)
        self.characters = characters
        self.offsets = offsets
    }

    var count: Int { characters.count }

    subscript(index: Int) -> Character { characters[index] }

    /// UTF-16の位置が文字の境目なら、その文字の番号。文字の途中ならnil。
    func index(atUTF16 offset: Int) -> Int? {
        var low = 0
        var high = offsets.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if offsets[middle] == offset { return middle }
            if offsets[middle] < offset { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    func utf16Offset(of index: Int) -> Int { offsets[index] }

    func string(_ range: Range<Int>) -> String {
        range.isEmpty ? "" : String(characters[range])
    }
}
