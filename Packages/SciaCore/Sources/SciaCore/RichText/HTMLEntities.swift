/// HTMLの文字参照（`&amp;`、`&#39;`、`&#x1F600;`など）を文字に戻す。
enum HTMLEntities {
    private static let named: [Substring: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
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
