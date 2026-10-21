/// HTMLの文字参照（`&amp;`、`&#39;`、`&#x1F600;`など）を文字に戻す。
enum HTMLEntities {
    /// Mastodonの本文に出るのは最初の6つだけだが、リンク先のページのタイトルでは、引用符やダッシュなどの名前もよく使われるため足している。
    /// HTMLの2000を超える名前を全部は持たない。ここにない名前は`&ndash;`のような表記のまま残るが、タイトルで見かける名前は数十に限られ、
    /// 全部を持つと表が大きくなる割に、使われる場面がほとんどないため。
    private static let named: [Substring: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "middot": "\u{00B7}", "bull": "\u{2022}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "sbquo": "\u{201A}", "bdquo": "\u{201E}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}", "plusmn": "\u{00B1}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "minus": "\u{2212}", "sect": "\u{00A7}", "para": "\u{00B6}",
        "yen": "\u{00A5}", "euro": "\u{20AC}", "pound": "\u{00A3}", "cent": "\u{00A2}",
        "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}", "darr": "\u{2193}", "hearts": "\u{2665}", "star": "\u{2606}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]

    static func decode(_ text: some StringProtocol) -> String {
        guard text.contains("&") else { return String(text) }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            // 文字参照は短いので、;が近くにないものは文字参照として扱わない。
            guard let semicolon = rest[afterAmp...].prefix(10).firstIndex(of: ";"),
                  let decoded = decodeReference(rest[afterAmp..<semicolon])
            else {
                result += "&"
                rest = rest[afterAmp...]
                continue
            }
            result += decoded
            rest = rest[rest.index(after: semicolon)...]
        }
        result += rest
        return result
    }

    private static func decodeReference(_ name: Substring) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        return named[name]
    }
}
