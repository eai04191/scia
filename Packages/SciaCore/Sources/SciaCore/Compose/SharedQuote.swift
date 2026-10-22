import Foundation

/// Safariなどの共有で受け取った、ページのタイトルとURLと選んだ文から、投稿欄の本文を作る。決まりはdocs/compose.mdの「共有で引用する」にある。
public enum SharedQuote {
    /// タイトル、URL、引用の順に1行ずつ並べ、引用は選んだ文の各行の頭に`> `を付ける。ないものは行ごと省く。どれもなければnil。
    /// 最後に改行を付ける。共有するのは感想を書くためなので、続けてすぐ次の行に書けるようにする。
    /// タイトルは`LinkTitling.normalizedTitle`で1行に整える。選んだ文の前後の空白と改行は外し、途中の空行も`>`だけの行にして段落の区切りを残す。
    public static func body(title: String?, url: String?, selection: String?) -> String? {
        let url = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let quote = selection.isEmpty
            ? nil
            : selection.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
        let lines = [LinkTitling.normalizedTitle(title), url.isEmpty ? nil : url, quote].compactMap(\.self)
        return lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n"
    }

    /// 本文の後ろに`shared`を足す。共有した本文が行の頭から始まるよう、本文が空か改行で終わっていなければ改行を挟む。返信の宛先だけの本文にも改行を挟む。
    public static func appending(_ shared: String, to text: String) -> String {
        guard let last = text.last, !last.isNewline else { return text + shared }
        return text + "\n" + shared
    }
}
