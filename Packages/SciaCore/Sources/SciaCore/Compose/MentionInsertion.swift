/// ユーザーのメニューの「メンション」で、投稿欄の本文に`@acct`を入れる。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
public enum MentionInsertion {
    /// 本文の`selection`を`@acct`で置き換えるもの。書いている途中の下書きを消さず、カーソルの位置に入れる。
    /// 前の文字とつながってメンションとして読まれないよう、直前が空白でも本文の先頭でもなければ前に空白を入れる。
    /// 続けて書けるよう、直後が空白でなければ後ろにも空白を入れ、カーソルはその空白の後ろに置く。
    /// - Parameter selection: 選んでいる範囲（UTF-16）。`UITextView`の位置と同じ数え方。本文の外にはみ出していれば、本文の中に収める。
    public static func insertion(of acct: String, in text: String, replacing selection: Range<Int>) -> TextInsertion {
        let length = text.utf16.count
        let lower = min(max(selection.lowerBound, 0), length)
        let upper = min(max(selection.upperBound, lower), length)
        let before = text.utf16.prefix(lower)
        let after = text.utf16.dropFirst(upper)
        let leading = before.last.map { isWhitespace($0) } ?? true ? "" : " "
        let followsSpace = after.first.map { isWhitespace($0) } ?? false
        let inserted = "\(leading)@\(acct)\(followsSpace ? "" : " ")"
        // 後ろにもとからある空白は、入れた文字に含めず、カーソルだけをその後ろへ動かす。
        let cursor = lower + inserted.utf16.count + (followsSpace ? 1 : 0)
        return TextInsertion(range: lower ..< upper, text: inserted, cursor: cursor)
    }

    private static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }
}

/// 本文の範囲を置き換えるもの。
public struct TextInsertion: Equatable, Sendable {
    /// 置き換える範囲（UTF-16）。`UITextView`の位置と同じ数え方。
    public let range: Range<Int>
    public let text: String
    /// 置き換えたあとに置くカーソルの位置（UTF-16）。
    public let cursor: Int
}
