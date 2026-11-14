/// いくつかの文言を1つの文に並べる。読み上げで名前、ハンドル、状態を続けて読ませるときや、選択肢やキーワードを1行に並べるときに使う。
/// 並べ方（区切りの記号）は言語で変わるので、UIでは区切りを書かずにここを通す。
public enum TextLists {
    /// `parts`を順に「、」で区切って並べる。空の文言も並べるので、除くものは渡す前に除く。
    public static func joined(_ parts: some Sequence<String>) -> String {
        parts.joined(separator: "、")
    }

    /// 人の名前とハンドルを並べた読み上げ。`acct`は先頭の`@`を除いたもの。
    public static func account(name: String, acct: String) -> String {
        joined([name, "@\(acct)"])
    }
}

extension Sequence<String> {
    /// `TextLists.joined(_:)`で並べた文。
    public var joinedAsTextList: String {
        TextLists.joined(self)
    }
}
