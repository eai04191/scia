extension RichText {
    /// 本文が、先頭のメンションを除いて絵文字と空白と改行だけなら、絵文字の数を返す。絵文字がないか、ほかのものがあればnil。
    /// カスタム絵文字と普通の絵文字は、どちらも1個と数える。
    /// 先頭のメンションは、Mastodonが返信の本文の先頭に自動で入れるので除く。最初の絵文字より後ろのメンションがあれば、絵文字だけとはみなさない。
    /// リスト項目は、番号や記号を描くので、絵文字だけとはみなさない。
    /// - Parameter isEmoji: 書記素クラスタが、絵文字の絵で描かれるか。書体によって変わるので、書式と段落から書体を決めて描く側が決める。
    public func emojiOnlyCount(isEmoji: (String, Style, Block) -> Bool) -> Int? {
        guard !blocks.contains(where: { $0.listMarker != nil }) else { return nil }
        var count = 0
        for (block, inline) in blocks.flatMap({ block in block.inlines.map { (block, $0) } }) {
            switch inline {
            case .emoji:
                count += 1
            case .lineBreak:
                continue
            case .link(_, .mention, _) where count == 0:
                continue
            case .link:
                return nil
            case .text(let text, let style):
                for character in text where !character.isWhitespace {
                    guard isEmoji(String(character), style, block) else { return nil }
                    count += 1
                }
            }
        }
        return count > 0 ? count : nil
    }
}
