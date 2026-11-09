/// ペーストか共有で入れたURLの後ろに、空白を挟まずに文字が続き、その文字までURLになったもの。決まりはdocs/compose.mdの「URLの後ろに続いた文字」にある。
public struct ExtendedURL: Equatable, Sendable {
    /// ペーストか共有で入れたURL。
    public let insertedURL: String
    /// URLの後ろに続いて、URLに入った文字。
    public let continuation: String
    /// 本文の中で、続いた文字が始まる位置（UTF-16）。改行を入れる位置。
    public let offset: Int

    public init(insertedURL: String, continuation: String, offset: Int) {
        self.insertedURL = insertedURL
        self.continuation = continuation
        self.offset = offset
    }

    /// `text`のURLのうち、`inserted`のどれかで始まり、それより長いもの。本文に出てくる順。
    /// `inserted`のどれかとまったく同じURLは含めない。始まりの合うものが複数あれば、いちばん長いものの後ろを続いた文字にする。
    /// URLは`LinkTitling`と同じく、UTF-8のバイト列で比べる。
    public static func find(in text: String, inserted: [String]) -> [ExtendedURL] {
        guard !inserted.isEmpty else { return [] }
        return StatusURLs.ranges(in: text).compactMap { range in
            let url = text[range]
            guard !inserted.contains(where: { $0.utf8.elementsEqual(url.utf8) }) else { return nil }
            guard let prefix = inserted.filter({ url.utf8.count > $0.utf8.count && url.utf8.starts(with: $0.utf8) }).max(by: { $0.utf8.count < $1.utf8.count }) else {
                return nil
            }
            // UTF-8の始まりが合っていれば、そこはUnicodeのスカラーの区切りになっている。
            let split = text.utf8.index(range.lowerBound, offsetBy: prefix.utf8.count)
            return ExtendedURL(
                insertedURL: prefix,
                continuation: String(text[split ..< range.upperBound]),
                offset: text.utf16.distance(from: text.startIndex, to: split)
            )
        }
    }

    /// `text`の、`found`の続いた文字の前に改行を入れたもの。
    public static func separating(_ found: [ExtendedURL], in text: String) -> String {
        var result = text
        for item in found.sorted(by: { $0.offset > $1.offset }) {
            let index = String.Index(utf16Offset: item.offset, in: result)
            result.insert("\n", at: index)
        }
        return result
    }
}

/// `ComposeModel.insertedTextToken`。読み始めたペーストが、今の下書きのものかを見分ける。
public struct InsertedTextToken: Equatable, Sendable {
    let generation: Int
}

/// ペーストか共有で入れたURLの後ろに文字が続いているとき、どう投稿するか。シートを閉じたら、どちらも選ばずに書いている欄に戻る。
public enum ExtendedURLChoice: Hashable, Sendable {
    /// 続いた文字の前に改行を入れて送る。
    case separate
    /// 続いた文字もURLのまま送る。
    case postAsIs
}

/// URLの後ろに文字が続いていることを知らせるシートの中身。
public struct ExtendedURLPrompt: Equatable, Sendable {
    /// 動きで見せる1つのURLと、その後ろに続いた文字。どちらも「…」で縮めず、見本の枠の端まで本物を出してフェードで消す。
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: Int
        /// 本文に書いたままのURL。
        public let url: String
        /// URLの後ろに続いた文字。見本の枠の幅を超える先は見えないので、`continuationLength`文字で切る。
        public let continuation: String
    }

    public let title: String
    public let lines: [Line]
    public let separateTitle: String
    public let postAsIsTitle: String
    /// VoiceOverに読ませる、改行を入れたあとの形。
    public let accessibilityDescription: String

    /// 題に続いた文字を挙げる長さ。これより長ければ、題を「…」で縮めずに、文字を挙げない題にする。
    static let titleQuoteLength = 20
    /// 続いた文字を見本に渡す長さ。細い文字（`i`など）が並んでも、見本の枠の幅を超えるだけの長さにする。
    static let continuationLength = 120

    /// `found`が空ならnil。
    public init?(_ found: [ExtendedURL], scheduling: Bool) {
        guard let first = found.first else { return nil }
        let action = scheduling ? "予約" : "投稿"
        lines = found.enumerated().map { index, item in
            Line(id: index, url: item.insertedURL, continuation: String(item.continuation.prefix(Self.continuationLength)))
        }
        title = found.count == 1 && first.continuation.count <= Self.titleQuoteLength
            ? "“\(first.continuation)”もリンクになります"
            : "URLの後ろの文字もリンクになります"
        separateTitle = "改行を入れて\(action)"
        postAsIsTitle = "そのまま\(action)"
        accessibilityDescription = lines.map { "改行を入れると、\($0.url)の次の行が“\($0.continuation)”になります。" }.joined()
    }
}
