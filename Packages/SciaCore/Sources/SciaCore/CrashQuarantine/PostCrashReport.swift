public import Foundation

/// クラッシュした投稿について、使う人が開発者へ送る文章。APIの応答の本文から作る。決まりはdocs/crash-quarantine.mdにある。
///
/// 応答を`Status`に変換せず、JSONのまま読む。投稿の変換や本文の解析がクラッシュの原因かもしれないため。
public struct PostCrashReport: Equatable, Sendable {
    public enum Failure: Error, Equatable {
        case unreadableResponse
    }

    /// ブラウザで開くページ。送る文章には、誰でも読める投稿のときのほかは入れない。
    public let postURL: URL?
    /// 既定で送る文章。誰でも読める投稿ならURL、それ以外なら本文を含まない構造の要約。
    public let text: String
    /// 本文の文字を置き換えたJSON。誰でも読める投稿ではURLで足りるのでnil。
    public let maskedJSON: String?

    /// - Parameter environment: 文章の末尾に添える、アプリの版と機種の1行。
    public init(response: Data, environment: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: response), let root = object as? [String: Any] else {
            throw Failure.unreadableResponse
        }
        let status = root["reblog"] as? [String: Any] ?? root
        postURL = Self.pageURL(of: status)
        if let url = Self.publicURL(of: status) {
            text = "\(url.absoluteString)\n\n\(environment)"
            maskedJSON = nil
            return
        }
        text = ([Self.withheldNotice(of: status), ""] + PostStructureSummary.lines(of: status) + [environment]).joined(separator: "\n")
        let masked = PostMasking.status(status)
        guard let data = try? JSONSerialization.data(withJSONObject: masked, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw Failure.unreadableResponse
        }
        maskedJSON = String(decoding: data, as: UTF8.self)
    }

    /// 誰でも読める投稿のURL。公開範囲が分からない投稿は、誰でも読めるとは扱わない。
    private static func publicURL(of status: [String: Any]) -> URL? {
        guard let visibility = status["visibility"] as? String, visibility == "public" || visibility == "unlisted" else { return nil }
        return pageURL(of: status)
    }

    /// 公開範囲が分かっているときだけ、理由を書く。URLがない公開の投稿や、公開範囲が分からない投稿も要約になるため。
    private static func withheldNotice(of status: [String: Any]) -> String {
        let visibility = status["visibility"] as? String
        return visibility == "private" || visibility == "direct" ? "公開投稿でないため本文は送信されません。" : "本文は送信されません。"
    }

    private static func pageURL(of status: [String: Any]) -> URL? {
        guard let string = status["url"] as? String, let url = URL(string: string) else { return nil }
        return ServerURLKind.destination.accepting(url)
    }
}

/// 投稿のHTMLを、タグと文字に分けたもの。不正なHTMLでも止まらないよう、`<`で始まり`>`で終わる範囲だけをタグとして扱う。
enum PostHTML {
    enum Token: Equatable {
        case tag(name: String, isClosing: Bool, isSelfClosing: Bool)
        case text(String)
    }

    static func tokens(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var rest = html[...]
        while let open = rest.firstIndex(of: "<") {
            let afterOpen = rest.index(after: open)
            guard afterOpen < rest.endIndex, let close = rest[afterOpen...].firstIndex(of: ">") else { break }
            let inner = rest[afterOpen..<close]
            let isClosing = inner.first == "/"
            let name = (isClosing ? inner.dropFirst() : inner).prefix { $0.isLetter || $0.isNumber }
            guard name.first?.isLetter == true else {
                tokens.append(.text(String(rest[..<rest.index(after: open)])))
                rest = rest[rest.index(after: open)...]
                continue
            }
            if open > rest.startIndex {
                tokens.append(.text(String(rest[..<open])))
            }
            tokens.append(.tag(name: name.lowercased(), isClosing: isClosing, isSelfClosing: inner.last == "/"))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty {
            tokens.append(.text(String(rest)))
        }
        return tokens
    }

    /// `&amp;`のような文字参照を1文字に数えられるよう、`&`1文字に置き換える。
    static func collapsingEntities(_ text: String) -> String {
        text.replacing(/&#?[0-9A-Za-z]{1,16};/) { _ in "&" }
    }
}

/// 投稿の構造を、人が読める行にする。ハンドル、URL、IDは行に入れない。ここに書いた項目のほかは出ない。
enum PostStructureSummary {
    static func lines(of status: [String: Any]) -> [String] {
        let tokens = PostHTML.tokens(status["content"] as? String ?? "")
        let text = PostHTML.collapsingEntities(tokens.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined())
        let customEmojiCount = (status["emojis"] as? [Any])?.count ?? 0
        let breaks = lineBreaks(in: tokens)
        let combiningRun = longestCombiningRun(in: text)
        // 該当しない項目は出さない。出ていなければ、その項目はない。
        let lines: [String?] = [
            "本文: \(text.count)文字、改行\(breaks.total)回（連続は最大\(breaks.longestRun)回）",
            characterKinds(in: text, customEmojiCount: customEmojiCount).map { "文字の種類: \($0)" },
            combiningRun > 0 ? "文字に重ねる記号: 最大\(combiningRun)個連続" : nil,
            tagSummary(tokens).map { "書式: \($0)" },
            spoiler(status).map { "注意書き: \($0)文字" },
            attachments(status).map { "添付: \($0)" },
            poll(status).map { "投票: \($0)" },
            quoteDepth(status).map { "引用: \($0)段" },
            status["card"] is [String: Any] ? "リンクカードあり" : nil,
        ]
        return lines.compactMap(\.self)
    }

    private static func lineBreaks(in tokens: [PostHTML.Token]) -> (total: Int, longestRun: Int) {
        var total = 0
        var run = 0
        var longest = 0
        func add(_ count: Int) {
            total += count
            run += count
            longest = max(longest, run)
        }
        for token in tokens {
            switch token {
            case .tag(name: "br", isClosing: false, _):
                add(1)
            case .tag:
                continue
            case .text(let text):
                for character in text {
                    if character.isNewline {
                        add(1)
                    } else if !character.isWhitespace {
                        run = 0
                    }
                }
            }
        }
        return (total, longest)
    }

    private static func characterKinds(in text: String, customEmojiCount: Int) -> String? {
        var kinds: [String] = []
        let scalars = Array(text.unicodeScalars)
        let names: [(String, (Unicode.Scalar) -> Bool)] = [
            ("かな", { PostMasking.Script(of: $0) == .kana }),
            ("漢字", { PostMasking.Script(of: $0) == .han }),
            ("英数字", { $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) }),
            ("ハングル", { PostMasking.Script(of: $0) == .hangul }),
            ("アラビア文字", { PostMasking.Script(of: $0) == .arabic }),
            ("ヘブライ文字", { PostMasking.Script(of: $0) == .hebrew }),
            ("そのほかの文字", { scalar in
                let script = PostMasking.Script(of: scalar)
                return script == .otherLetter || (script == .digit && !scalar.isASCII)
            }),
        ]
        for (name, matches) in names where scalars.contains(where: matches) {
            kinds.append(name)
        }
        let emojiCount = text.reduce(0) { $0 + (PostMasking.isEmoji($1) ? 1 : 0) }
        if emojiCount > 0 {
            kinds.append("絵文字\(emojiCount)個")
        }
        if customEmojiCount > 0 {
            kinds.append("カスタム絵文字\(customEmojiCount)個")
        }
        let controlCount = scalars.count { scalar in
            let category = scalar.properties.generalCategory
            return (category == .control && !scalar.properties.isWhitespace) || category == .format
        }
        if controlCount > 0 {
            kinds.append("見えない制御文字\(controlCount)個")
        }
        if kinds.isEmpty {
            return text.allSatisfy(\.isWhitespace) ? nil : "記号のみ"
        }
        return kinds.joined(separator: "、")
    }

    private static func longestCombiningRun(in text: String) -> Int {
        var run = 0
        var longest = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                run += 1
                longest = max(longest, run)
            default:
                run = 0
            }
        }
        return longest
    }

    private static func tagSummary(_ tokens: [PostHTML.Token]) -> String? {
        var counts: [String: Int] = [:]
        // 改行は本文の行で数えている。
        for case .tag(let name, false, _) in tokens where name != "br" {
            counts[name, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        let known = [("p", "段落"), ("a", "リンク")]
        var parts = known.compactMap { tag, label in counts[tag].map { "\(label)\($0)個" } }
        let others = counts.filter { key, _ in !known.contains { $0.0 == key } }.values.reduce(0, +)
        if others > 0 {
            parts.append("そのほか\(others)個")
        }
        return parts.joined(separator: "、")
    }

    private static func spoiler(_ status: [String: Any]) -> Int? {
        let text = status["spoiler_text"] as? String ?? ""
        return text.isEmpty ? nil : text.count
    }

    private static func attachments(_ status: [String: Any]) -> String? {
        let items = status["media_attachments"] as? [[String: Any]] ?? []
        guard !items.isEmpty else { return nil }
        let names = [("image", "画像"), ("video", "動画"), ("gifv", "GIF"), ("audio", "音声")]
        var parts: [String] = []
        for (type, name) in names {
            let matching = items.filter { $0["type"] as? String == type }
            guard !matching.isEmpty else { continue }
            let sizes = matching.map(size(of:)).joined(separator: "、")
            parts.append("\(name)\(matching.count)枚（\(sizes)）")
        }
        let others = items.count { item in !names.contains { $0.0 == item["type"] as? String } }
        if others > 0 {
            parts.append("そのほか\(others)個")
        }
        let describedCount = items.count { !($0["description"] as? String ?? "").isEmpty }
        return (parts + (describedCount > 0 ? ["代替テキストあり\(describedCount)個"] : [])).joined(separator: "、")
    }

    private static func size(of attachment: [String: Any]) -> String {
        let meta = (attachment["meta"] as? [String: Any])?["original"] as? [String: Any]
        guard let width = (meta?["width"] as? NSNumber)?.intValue, let height = (meta?["height"] as? NSNumber)?.intValue else { return "大きさ不明" }
        return "\(width)×\(height)"
    }

    private static func poll(_ status: [String: Any]) -> String? {
        guard let poll = status["poll"] as? [String: Any] else { return nil }
        return "選択肢\((poll["options"] as? [Any])?.count ?? 0)個"
    }

    private static func quoteDepth(_ status: [String: Any]) -> Int? {
        var depth = 0
        var current = status
        while depth < 16, let quote = current["quote"] as? [String: Any] {
            depth += 1
            guard let quoted = quote["quoted_status"] as? [String: Any] else { break }
            current = quoted
        }
        return depth > 0 ? depth : nil
    }
}

/// 投稿のJSONの文字を、形を保ったまま置き換える。ここで作る項目のほかは出ない。サーバーが独自の項目を足しても、中身が混ざらないようにするため。
enum PostMasking {
    enum Script: Equatable {
        case latin, digit, kana, han, hangul, arabic, hebrew, otherLetter, keep

        init(of scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x30...0x39: self = .digit
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: self = .kana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: self = .han
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: self = .hangul
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: self = Script.lettersOnly(scalar, .arabic)
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: self = Script.lettersOnly(scalar, .hebrew)
            default:
                let category = scalar.properties.generalCategory
                if category == .decimalNumber || category == .letterNumber || category == .otherNumber {
                    self = .digit
                } else if !scalar.properties.isAlphabetic {
                    self = .keep
                } else if scalar.isASCII {
                    self = .latin
                } else {
                    self = Script.lettersOnly(scalar, .otherLetter)
                }
            }
        }

        /// 結合文字は文字として置き換えず、そのまま残す。連続の長さがクラッシュに関わることがあるため。
        private static func lettersOnly(_ scalar: Unicode.Scalar, _ script: Script) -> Script {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format, .control: .keep
            default: script
            }
        }
    }

    static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && character.unicodeScalars.count > 1 && !first.isASCII)
    }

    /// 文字を同じ種類の文字に置き換える。長さ、空白、記号、絵文字、結合文字、制御文字は残す。
    static func text(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            view.append(masked(scalar))
        }
        return String(view)
    }

    private static func masked(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.properties.isEmoji, !scalar.isASCII { return scalar }
        return switch Script(of: scalar) {
        case .latin: scalar.properties.isUppercase ? "A" : "a"
        case .digit: "0"
        case .kana: "あ"
        case .han: "亜"
        case .hangul: "가"
        case .arabic: "ا"
        case .hebrew: "א"
        case .otherLetter: "x"
        case .keep: scalar
        }
    }

    /// 投稿のHTMLの、文字だけを置き換える。タグの属性はリンク先のほかは外し、リンク先も決まったURLにする。
    static func html(_ html: String) -> String {
        PostHTML.tokens(html).map { token in
            switch token {
            case .text(let text):
                return maskedKeepingEntities(text)
            case .tag(let name, true, _):
                return "</\(allowedTag(name))>"
            case .tag(let name, false, let isSelfClosing):
                let tag = allowedTag(name)
                let attributes = tag == "a" ? " href=\"\(placeholderURL)\"" : ""
                return "<\(tag)\(attributes)\(isSelfClosing ? " /" : "")>"
            }
        }.joined()
    }

    /// タグの名前は、不正な応答では投稿の内容を含みうる。Mastodonが返す名前のほかは`span`にする。
    private static func allowedTag(_ name: String) -> String {
        allowedTags.contains(name) ? name : "span"
    }

    private static let allowedTags: Set<String> = [
        "p", "br", "a", "span", "del", "pre", "blockquote", "code", "b", "strong", "u", "i", "em",
        "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "sub", "sup", "ruby", "rt", "rp", "s",
    ]

    private static func allowedValue(_ value: Any?, in allowed: Set<String>, otherwise fallback: String) -> String {
        guard let value = value as? String, allowed.contains(value) else { return fallback }
        return value
    }

    private static func maskedKeepingEntities(_ source: String) -> String {
        var result = ""
        var rest = source[...]
        while let match = rest.firstMatch(of: /&#?[0-9A-Za-z]{1,16};/) {
            result += text(String(rest[..<match.range.lowerBound]))
            // 文字参照の中身も文字なので、数字の参照は投稿の内容を含みうる。決まった参照にする。
            result += "&amp;"
            rest = rest[match.range.upperBound...]
        }
        return result + text(String(rest))
    }

    static let placeholderURL = "https://example.invalid/"
    private static let placeholderDate = "2026-01-01T00:00:00.000Z"

    static func status(_ status: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "id": "1",
            "created_at": placeholderDate,
            "account": account(status["account"] as? [String: Any] ?? [:]),
            "content": html(status["content"] as? String ?? ""),
            "spoiler_text": text(status["spoiler_text"] as? String ?? ""),
            "uri": placeholderURL,
            "url": placeholderURL,
            "mentions": [Any](),
            "tags": [Any](),
            "emojis": ((status["emojis"] as? [[String: Any]]) ?? []).map(emoji),
            "media_attachments": ((status["media_attachments"] as? [[String: Any]]) ?? []).enumerated().map(attachment),
            "sensitive": status["sensitive"] as? Bool ?? false,
            // 表示に関わる値で、4種類のどれかを示すだけなので伏せない。知らない値は投稿した人が決めた文字列かもしれないので出さない。
            "visibility": allowedValue(status["visibility"], in: ["public", "unlisted", "private", "direct"], otherwise: "private"),
            "favourites_count": 0,
            "reblogs_count": 0,
            "replies_count": 0,
        ]
        if let poll = status["poll"] as? [String: Any] {
            result["poll"] = self.poll(poll)
        }
        if let card = status["card"] as? [String: Any] {
            result["card"] = self.card(card)
        }
        if let quote = status["quote"] as? [String: Any] {
            var masked: [String: Any] = ["state": "accepted"]
            if let quoted = quote["quoted_status"] as? [String: Any] {
                masked["quoted_status"] = self.status(quoted)
            }
            result["quote"] = masked
        }
        return result
    }

    private static func account(_ account: [String: Any]) -> [String: Any] {
        [
            "id": "1",
            "username": "user",
            "acct": "user",
            "display_name": text(account["display_name"] as? String ?? ""),
            "note": "",
            "url": placeholderURL,
            "avatar": placeholderURL,
            "avatar_static": placeholderURL,
            "header": placeholderURL,
            "header_static": placeholderURL,
            "locked": false,
            "bot": false,
            "created_at": placeholderDate,
            "followers_count": 0,
            "following_count": 0,
            "statuses_count": 0,
            "emojis": ((account["emojis"] as? [[String: Any]]) ?? []).map(emoji),
            "fields": [Any](),
        ]
    }

    private static func emoji(_ emoji: [String: Any]) -> [String: Any] {
        [
            "shortcode": text(emoji["shortcode"] as? String ?? ""),
            "url": placeholderURL,
            "static_url": placeholderURL,
            "visible_in_picker": false,
        ]
    }

    private static func attachment(_ index: Int, _ attachment: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "id": String(index + 1),
            "type": allowedValue(attachment["type"], in: ["image", "video", "gifv", "audio"], otherwise: "unknown"),
            "url": placeholderURL,
            "preview_url": placeholderURL,
        ]
        if let description = attachment["description"] as? String {
            result["description"] = text(description)
        }
        if let meta = attachment["meta"] as? [String: Any] {
            result["meta"] = self.meta(meta)
        }
        return result
    }

    private static func meta(_ meta: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["original", "small"] {
            guard let size = meta[key] as? [String: Any] else { continue }
            result[key] = size.filter { ["width", "height", "aspect", "duration"].contains($0.key) && $0.value is NSNumber }
        }
        return result
    }

    private static func poll(_ poll: [String: Any]) -> [String: Any] {
        [
            "id": "1",
            "expires_at": NSNull(),
            "expired": poll["expired"] as? Bool ?? false,
            "multiple": poll["multiple"] as? Bool ?? false,
            "votes_count": poll["votes_count"] as? NSNumber ?? 0,
            "voters_count": poll["voters_count"] as? NSNumber ?? NSNull(),
            "voted": false,
            "own_votes": [Any](),
            "emojis": ((poll["emojis"] as? [[String: Any]]) ?? []).map(emoji),
            "options": ((poll["options"] as? [[String: Any]]) ?? []).map { option -> [String: Any] in
                ["title": text(option["title"] as? String ?? ""), "votes_count": option["votes_count"] as? NSNumber ?? NSNull()]
            },
        ]
    }

    private static func card(_ card: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "url": placeholderURL,
            "title": text(card["title"] as? String ?? ""),
            "description": text(card["description"] as? String ?? ""),
            "type": allowedValue(card["type"], in: ["link", "photo", "video", "rich"], otherwise: "link"),
            "author_name": "",
            "author_url": "",
            "provider_name": "",
            "provider_url": "",
            "html": "",
            "width": card["width"] as? NSNumber ?? 0,
            "height": card["height"] as? NSNumber ?? 0,
            "embed_url": "",
        ]
        if card["image"] is String {
            result["image"] = placeholderURL
        }
        return result
    }
}
