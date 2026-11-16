/// いくつかの文言を並べる。並べ方（区切りの記号）は言語で変わるので、UIでは区切りを書かずにここを通す。
/// 画面に並べるアイテムは`items(_:)`、文字でしか出せないところは`plain(_:)`、読み上げは`joined(_:)`を使う。
public enum TextLists {
    /// 並べたアイテム。画面では、区切りの範囲を境界線に置き換えて描く。
    public struct ItemList: Equatable, Sendable {
        /// アイテムを「・」で区切って並べた文。
        public let text: String
        /// `text`の中の区切りの範囲。アイテムに「・」が入っていても、区切りだけを指す。
        public let separators: [Range<String.Index>]
        /// 読み上げる文。
        public let spoken: String

        /// 区切りのない1つの文言。並べるものがないときの「なし」などに使う。
        public init(single text: String) {
            self.text = text
            separators = []
            spoken = text
        }

        init(_ parts: [String]) {
            var text = ""
            var offsets: [Int] = []
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    offsets.append(text.utf16.count)
                    text += plainSeparator
                }
                text += part
            }
            self.text = text
            // 結合文字で始まるアイテムは区切りと1文字にまとまるので、文字の数ではなくUTF-16の位置で指す。
            separators = offsets.map { TextLists.range(utf16Offset: $0, length: plainSeparator.utf16.count, in: text) }
            spoken = TextLists.joined(parts)
        }
    }

    static let plainSeparator = "・"

    static func range(utf16Offset: Int, length: Int, in text: String) -> Range<String.Index> {
        let start = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        return start..<text.utf16.index(start, offsetBy: length)
    }

    /// 画面に並べるアイテム。空の文言も並べるので、除くものは渡す前に除く。
    public static func items(_ parts: some Sequence<String>) -> ItemList {
        ItemList(Array(parts))
    }

    /// 境界線を引けない、文字だけの出し先（送る文面など）に並べる。`parts`を順に「・」で区切る。
    public static func plain(_ parts: some Sequence<String>) -> String {
        parts.joined(separator: plainSeparator)
    }

    /// 読み上げで名前、ハンドル、状態を続けて読ませる。`parts`を順に「、」で区切る。空の文言も並べるので、除くものは渡す前に除く。
    public static func joined(_ parts: some Sequence<String>) -> String {
        parts.joined(separator: "、")
    }

    /// 人の名前とハンドルを並べた読み上げ。`acct`は先頭の`@`を除いたもの。
    public static func account(name: String, acct: String) -> String {
        joined([name, "@\(acct)"])
    }
}

extension Sequence<String> {
    /// `TextLists.joined(_:)`で並べた、読み上げの文。
    public var joinedAsTextList: String {
        TextLists.joined(self)
    }
}
