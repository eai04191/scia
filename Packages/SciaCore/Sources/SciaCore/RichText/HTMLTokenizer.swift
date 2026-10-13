/// MastodonがサニタイズしたHTMLを、タグと文字に分ける。汎用のHTMLパーサーではない。
enum HTMLToken: Equatable {
    case text(Substring)
    case open(name: String, attributes: [String: String])
    case close(name: String)
}

enum HTMLTokenizer {
    static func tokenize(_ html: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var rest = Substring(html)
        while !rest.isEmpty {
            guard let lt = rest.firstIndex(of: "<") else {
                tokens.append(.text(rest))
                break
            }
            if lt > rest.startIndex {
                tokens.append(.text(rest[..<lt]))
            }
            let afterLT = rest.index(after: lt)
            if rest[afterLT...].hasPrefix("!--") {
                // コメントは読み飛ばす。閉じがなければ残りをすべて捨てる。
                guard let end = rest[afterLT...].firstRange(of: "-->") else { break }
                rest = rest[end.upperBound...]
                continue
            }
            guard let gt = tagEnd(in: rest[afterLT...]) else {
                // 閉じていない`<`は文字として扱う。
                tokens.append(.text(rest[lt...]))
                break
            }
            if let token = parseTag(rest[afterLT..<gt]) {
                tokens.append(token)
            }
            rest = rest[rest.index(after: gt)...]
        }
        return tokens
    }

    /// 属性値の引用符の中の`>`を無視して、タグの閉じを探す。
    private static func tagEnd(in text: Substring) -> Substring.Index? {
        var quote: Character?
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
        }
        return nil
    }

    private static func parseTag(_ body: Substring) -> HTMLToken? {
        var body = body
        if body.hasPrefix("/") {
            let name = body.dropFirst().prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            return name.isEmpty ? nil : .close(name: name)
        }
        if body.hasSuffix("/") {
            body = body.dropLast()
        }
        let name = body.prefix { !$0.isWhitespace }.lowercased()
        guard !name.isEmpty, name.first?.isLetter == true else { return nil }
        return .open(name: name, attributes: parseAttributes(body.dropFirst(name.count)))
    }

    private static func parseAttributes(_ text: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var rest = text
        while true {
            rest = rest.drop { $0.isWhitespace }
            let name = rest.prefix { !$0.isWhitespace && $0 != "=" }
            guard !name.isEmpty else { break }
            rest = rest.dropFirst(name.count).drop { $0.isWhitespace }
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop { $0.isWhitespace }
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    let afterQuote = rest.dropFirst()
                    let raw = afterQuote.prefix { $0 != quote }
                    value = HTMLEntities.decode(raw)
                    rest = afterQuote.dropFirst(raw.count).dropFirst()
                } else {
                    let raw = rest.prefix { !$0.isWhitespace }
                    value = HTMLEntities.decode(raw)
                    rest = rest.dropFirst(raw.count)
                }
            }
            attributes[name.lowercased()] = value
        }
        return attributes
    }
}
