/// 投稿欄で、本文のリンクにリンク先のページのタイトルを付ける。決まりはdocs/compose.mdの「リンクにタイトルを付ける」にある。
public enum LinkTitling {
    /// 本文にあるURL。出てくる順に並べ、同じURLは1つにまとめる。
    /// URLは文字列の`==`ではなくUTF-8のバイト列で比べる。`==`は合成済みの「é」と、「e」と結合文字の「é」を同じとみなすが、
    /// パーセントエンコードすると別のURLになるため。
    public static func urls(in text: String) -> [String] {
        var seen: Set<[UInt8]> = []
        return StatusURLs.ranges(in: text).map { String(text[$0]) }.filter { seen.insert(Array($0.utf8)).inserted }
    }

    /// 本文に出てくるURLの1つ1つ。同じURLが2回あれば、2つとも並べる。ハイライトして選ばせるときに、押した場所を置き換えるため。
    public static func occurrences(in text: String) -> [LinkOccurrence] {
        StatusURLs.ranges(in: text).map { range in
            let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.utf16.distance(from: text.startIndex, to: range.upperBound)
            return LinkOccurrence(url: String(text[range]), range: start ..< end)
        }
    }

    /// 本文の`url`のうち、`location`にいちばん近いもの。nilなら最初のもの。同じだけ離れていれば、前のもの。
    /// 長いURLの先頭が`url`と同じでも、別のURLなので選ばない。`urls(in:)`と同じく、UTF-8のバイト列で比べる。
    public static func occurrence(of url: String, nearestTo location: Int?, in text: String) -> LinkOccurrence? {
        let candidates = occurrences(in: text).filter { $0.url.utf8.elementsEqual(url.utf8) }
        guard let location else { return candidates.first }
        return candidates.min { abs($0.range.lowerBound - location) < abs($1.range.lowerBound - location) }
    }

    /// 本文の`url`の前にタイトルを入れるもの。`url`が本文になければnil。
    /// URLが行の頭にあれば、タイトルを1行にして改行で区切り、文の途中なら空白で区切る。決まりはdocs/compose.mdの「リンクにタイトルを付ける」にある。
    /// - Parameters:
    ///   - title: `normalizedTitle`で整えたタイトル。
    ///   - location: 押したURLの、押した時点の位置。読んでいる間に前で打たれてずれても、いちばん近いものを置き換える。nilなら最初のもの。
    public static func replacement(of url: String, title: String, in text: String, nearestTo location: Int? = nil) -> LinkTitleReplacement? {
        guard let occurrence = occurrence(of: url, nearestTo: location, in: text) else { return nil }
        let before = text[..<String.Index(utf16Offset: occurrence.range.lowerBound, in: text)]
        // 行の頭は、本文の先頭か改行の直後で、URLの前にその行の空白しかないところ。
        if before.reversed().prefix(while: { !$0.isNewline }).allSatisfy(\.isWhitespace) {
            return LinkTitleReplacement(range: occurrence.range, leading: "", title: title, separator: "\n", url: url)
        }
        // URLの直前が空白でない文字なら、タイトルが前の文とつながらないよう、タイトルの前にも空白を入れる。
        let followsSpace = before.last?.isWhitespace ?? true
        return LinkTitleReplacement(range: occurrence.range, leading: followsSpace ? "" : " ", title: title, separator: " ", url: url)
    }

    /// 本文に入れるタイトル。改行を含む空白の続きを1つの空白にし、前後の空白を除く。何も残らなければnil。
    public static func normalizedTitle(_ title: String?) -> String? {
        let words = (title ?? "").split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}

/// 本文に出てくるURLの1つ。
public struct LinkOccurrence: Equatable, Sendable {
    public let url: String
    /// 本文の中の範囲（UTF-16）。`UITextView`の位置と同じ数え方。
    public let range: Range<Int>

    /// 本文の別の場所を`replacement`で置き換えたあとの、このURLの場所。後ろにあれば、増えた分だけずらす。
    /// 同じURLを2か所続けて読んだとき、先に置き換えた分で、後の読み込みの場所がずれるため。
    public func adjusted(afterReplacing replacement: LinkTitleReplacement) -> LinkOccurrence {
        guard range.lowerBound >= replacement.range.upperBound else { return self }
        let delta = replacement.text.utf16.count - replacement.range.count
        return LinkOccurrence(url: url, range: range.lowerBound + delta ..< range.upperBound + delta)
    }
}

/// 本文のURLを、タイトルを付けた形に置き換えるもの。
public struct LinkTitleReplacement: Equatable, Sendable {
    /// 置き換える範囲（UTF-16）。`UITextView`の位置と同じ数え方。
    public let range: Range<Int>
    public let text: String
    /// 置き換えたあとの本文での、タイトルの範囲（UTF-16）。タイトルを浮かび上がらせるため。
    public let titleRange: Range<Int>
    /// 置き換えたあとの本文での、URLの範囲（UTF-16）。URLを置き換えたあとの位置へ動かすため。
    public let urlRange: Range<Int>

    /// - Parameters:
    ///   - leading: タイトルの前に入れるもの。前の文とつながらないようにする空白。
    ///   - separator: タイトルとURLの間に入れる改行か空白。
    init(range: Range<Int>, leading: String, title: String, separator: String, url: String) {
        self.range = range
        text = leading + title + separator + url
        let titleStart = range.lowerBound + leading.utf16.count
        titleRange = titleStart ..< titleStart + title.utf16.count
        let urlStart = titleRange.upperBound + separator.utf16.count
        urlRange = urlStart ..< urlStart + url.utf16.count
    }
}
