public import Foundation

/// リンク先のページのHTMLから、本文に入れるタイトルを読む。
/// og:titleを優先し、なければ最初の`<title>`を使う。YouTubeの`<title>`は「- YouTube」が付き、ページの初めには中身のない`<title>YouTube</title>`もあるため。
///
/// HTMLは組み立てず、全体に正規表現もかけない。バイト列で`og:title`と`<title`の場所を探し、その近くの決まった幅だけを文字にして読む。
/// 読む量は上限まで来るたびに確かめ直すため、全体を読み直したり、閉じのないタグのたびに末尾まで探したりすると、
/// `og:title`や`<title`を大量に並べたページで、手間が2乗で増えて端末が固まるため。
/// 幅に収まらない長いタグや、調べる数を超えた先のog:titleは見つけられないが、そのようなページは実際には見かけない。
public enum PageTitle {
    /// 調べる`og:title`の出現の数。scriptの中などに同じ文字列があっても、本物のmetaはこの数のうちに出てくる。
    static let maxOGTitleCandidates = 32
    /// 調べる`<title`の出現の数。
    static let maxTitleCandidates = 8
    /// `og:title`から前にさかのぼって`<meta`を探す幅。
    static let metaLookBehind = 512
    /// タグの終わりや`</title>`を探す幅。
    static let tagWindow = 4096

    public static func title(in data: Data, contentType: String?) -> String? {
        var scanned = 0
        return title(in: data, contentType: contentType, scanned: &scanned)
    }

    /// - Parameter scanned: 探すのに見たバイトの数を足す。テストで、手間がページの大きさに比例して収まることを、時間を測らずに確かめる。
    static func title(in data: Data, contentType: String?, scanned: inout Int) -> String? {
        let encoding = encoding(of: data, contentType: contentType)
        return ogTitle(in: data, encoding: encoding, scanned: &scanned) ?? titleElement(in: data, encoding: encoding, scanned: &scanned)
    }

    /// 空でないog:titleのmetaを、閉じの`>`まで読んだか。読み終えていれば、残りを読まずに止めてよい。
    /// scriptの中の`og:title`という文字列や、空のog:titleでは止めない。本物のog:titleがあとに出てくることがあるため。
    /// - Parameter offset: ここより前は前回までに調べ済み。調べ済みの分を読み直さないよう、ここから探す。
    ///   前回の終わりで切れていたタグも見つけられるよう、渡す側はタグの幅の分だけ手前にずらして渡す。
    public static func hasOGTitle(in data: Data, contentType: String?, searchingFrom offset: Int = 0) -> Bool {
        var scanned = 0
        return hasOGTitle(in: data, contentType: contentType, searchingFrom: offset, scanned: &scanned)
    }

    /// - Parameter scanned: 探すのに見たバイトの数を足す。
    static func hasOGTitle(in data: Data, contentType: String?, searchingFrom offset: Int = 0, scanned: inout Int) -> Bool {
        ogTitle(in: data, encoding: encoding(of: data, contentType: contentType), from: offset, scanned: &scanned) != nil
    }

    private static func ogTitle(in data: Data, encoding: String.Encoding, from offset: Int = 0, scanned: inout Int) -> String? {
        let tags: [Range<Int>] = data.withUnsafeBytes { bytes in
            var tags: [Range<Int>] = []
            var from = max(0, offset)
            for _ in 0..<maxOGTitleCandidates {
                guard let found = find("og:title", in: bytes, from: from, to: bytes.count, scanned: &scanned) else { break }
                from = found + 1
                guard let start = findLast("<meta", in: bytes, from: max(0, found - metaLookBehind), to: found, scanned: &scanned),
                      let end = tagEnd(in: bytes, from: start, scanned: &scanned)
                else { continue }
                tags.append(start..<end)
            }
            return tags
        }
        for tag in tags {
            let attributes = attributes(in: text(of: data, range: tag, encoding: encoding))
            let key = (attributes["property"] ?? attributes["name"])?.lowercased()
            if key == "og:title", let content = attributes["content"].map(HTMLEntities.decode), !content.isEmpty {
                return content
            }
        }
        return nil
    }

    /// 中身が閉じの`</title>`まで幅に収まる、最初の`<title>`の中身。`<title>`の中身は文字だけなので、`<`を含んでも閉じのタグまでを中身にする。
    private static func titleElement(in data: Data, encoding: String.Encoding, scanned: inout Int) -> String? {
        let inner: Range<Int>? = data.withUnsafeBytes { bytes in
            var from = 0
            for _ in 0..<maxTitleCandidates {
                guard let found = find("<title", in: bytes, from: from, to: bytes.count, scanned: &scanned) else { return nil }
                from = found + 1
                // `<titlex`のような別の名前のタグを除く。
                let next = found + 6
                guard next < bytes.count, bytes[next] == UInt8(ascii: ">") || isSpace(bytes[next]),
                      let open = tagEnd(in: bytes, from: found, scanned: &scanned),
                      let close = find("</title", in: bytes, from: open, to: min(bytes.count, open + tagWindow), scanned: &scanned)
                else { continue }
                return open..<close
            }
            return nil
        }
        guard let inner else { return nil }
        let title = HTMLEntities.decode(text(of: data, range: inner, encoding: encoding))
        return title.isEmpty ? nil : title
    }

    /// `start`の`<`から始まるタグの、閉じの`>`の次の位置。属性の値の中の`>`でタグを切らないよう、引用符の中は読み飛ばす。幅に収まらなければnil。
    private static func tagEnd(in bytes: UnsafeRawBufferPointer, from start: Int, scanned: inout Int) -> Int? {
        var quote: UInt8?
        let end = min(bytes.count, start + tagWindow)
        for index in start..<end {
            let byte = bytes[index]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                scanned += index + 1 - start
                return index + 1
            }
        }
        scanned += end - start
        return nil
    }

    /// `from`から`to`の間で`needle`を探す。1バイトずつ比べると遅いため、バイト列の検索で探す。
    /// 大文字と小文字の違いは、すべての組み合わせではなく、HTMLでよく見る書き方（小文字、大文字、先頭の英字だけ大文字）だけを探す。
    private static func find(_ needle: String, in bytes: UnsafeRawBufferPointer, from: Int, to: Int, scanned: inout Int) -> Int? {
        guard to - from >= needle.utf8.count, let base = bytes.baseAddress else { return nil }
        let haystack = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + from), count: to - from, deallocator: .none)
        let found = spellings(of: needle).map { haystack.range(of: $0) }
        // 見つからなかった書き方は、末尾まで見ている。
        scanned += found.reduce(0) { $0 + ($1?.upperBound ?? haystack.count) }
        return found.compactMap { $0?.lowerBound }.min().map { $0 + from }
    }

    private static func spellings(of needle: String) -> [Data] {
        let lower = needle.lowercased()
        var capitalized = Array(lower.utf8)
        if let first = capitalized.firstIndex(where: { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) {
            capitalized[first] -= 32
        }
        return [Data(lower.utf8), Data(needle.uppercased().utf8), Data(capitalized)]
    }

    private static func findLast(_ needle: String, in bytes: UnsafeRawBufferPointer, from: Int, to: Int, scanned: inout Int) -> Int? {
        let needle = Array(needle.utf8)
        guard to - from >= needle.count else { return nil }
        let found = (from...(to - needle.count)).reversed().first { matches(needle, in: bytes, at: $0) }
        scanned += to - (found ?? from)
        return found
    }

    private static func matches(_ needle: [UInt8], in bytes: UnsafeRawBufferPointer, at index: Int) -> Bool {
        needle.indices.allSatisfy { lowercased(bytes[index + $0]) == needle[$0] }
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    private static let attributePattern = regex(#"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let metaCharsetPattern = regex(#"<meta\b[^>]*charset\s*=\s*["']?([-A-Za-z0-9_:.]+)"#)
    private static let headerCharsetPattern = regex(#"charset\s*=\s*["']?([-A-Za-z0-9_:.]+)"#)

    /// 属性の名前を小文字にして、値を引く。
    private static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let name = Range(match.range(at: 1), in: tag) else { continue }
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            result[tag[name].lowercased()] = value
        }
        return result
    }

    /// 文字コードは、ヘッダーのcharset、ページの初めのmetaのcharset、UTF-8の順に決める。
    private static func encoding(of data: Data, contentType: String?) -> String.Encoding {
        contentType.flatMap { charset(in: $0, pattern: headerCharsetPattern) }
            ?? charset(in: String(decoding: data.prefix(2048), as: UTF8.self), pattern: metaCharsetPattern)
            ?? .utf8
    }

    /// 切り出した範囲を文字にする。範囲は`<`や`>`のようなASCIIの文字で区切るので、Shift_JISなどでも文字の途中では切れない。
    /// 読む量の上限で、複数バイトの文字の途中で切れた`<title>`の中身のために、読めなければ末尾を数バイトずつ削って読み直す。
    private static func text(of data: Data, range: Range<Int>, encoding: String.Encoding) -> String {
        let slice = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
        for dropped in 0...3 {
            if let text = String(data: slice.dropLast(dropped), encoding: encoding) {
                return text
            }
        }
        return String(decoding: slice, as: UTF8.self)
    }

    private static func charset(in text: String, pattern: NSRegularExpression) -> String.Encoding? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let name = Range(match.range(at: 1), in: text)
        else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(text[name] as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    // パターンは固定の文字列で、組み立てに失敗するのは書き間違えたときだけなので、起動時に止める。
    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("正規表現が不正です: \(pattern)")
        }
    }
}

/// リンク先のページを読み、`PageTitle`でタイトルを読む。
/// YouTubeはog:titleがHTMLの500KBを過ぎたあたりにあるため、og:titleのmetaを読み終えるまで、上限まで読み進める。
public struct PageTitleLoader: Sendable {
    /// 読む量の上限。YouTubeの動画のページは全体で700KBほど。
    public static let maxByteCount = 2_000_000
    private static let checkInterval = 16_384

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// HTMLでないページ（画像やPDFなど）と、タイトルのないページはnil。
    public func title(of url: URL) async throws -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw PageTitleLoadError.status(http.statusCode) }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard Self.isHTML(contentType) else { return nil }
        var data = Data()
        var checked = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.maxByteCount { break }
            if data.count - checked >= Self.checkInterval {
                let searchFrom = checked - PageTitle.metaLookBehind - PageTitle.tagWindow
                checked = data.count
                if PageTitle.hasOGTitle(in: data, contentType: contentType, searchingFrom: searchFrom) { break }
            }
        }
        return PageTitle.title(in: data, contentType: contentType)
    }

    /// ヘッダーがなければ、HTMLとみなして読んでみる。
    static func isHTML(_ contentType: String?) -> Bool {
        guard let mime = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), !mime.isEmpty else { return true }
        return mime == "text/html" || mime == "application/xhtml+xml"
    }
}

/// リンク先のページを読めなかった。
public enum PageTitleLoadError: Error, Equatable {
    /// 2xx以外のステータスが返った。
    case status(Int)
}
