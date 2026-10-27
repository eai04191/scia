import Foundation

/// プロフィール画面で長押ししてメニューを出す文章のまとまり。決まりはdocs/menus.mdの「プロフィールの文章のメニュー」にある。
public enum ProfileTextPart: Hashable, Sendable {
    case displayName
    case note
    /// `Account.fields`の何番目の補足情報か。
    case field(Int)
}

/// 長押しした文章の、コピーと翻訳に渡す文字と、描いているカスタム絵文字。
public struct ProfileText: Equatable, Sendable {
    /// 書式とリンクを落とした文字。カスタム絵文字は`:shortcode:`のまま残す。空白だけならnil。
    public let text: String?
    /// 文章に描いているカスタム絵文字を、出てくる順に並べる。同じ画像の絵文字は1度だけ数える。
    public let emojis: [CustomEmoji]

    init(text: RichText, emojiSources: [RichText]) {
        let plain = text.plainText
        self.text = plain.allSatisfy(\.isWhitespace) ? nil : plain
        var seen: Set<URL> = []
        emojis = emojiSources.flatMap(\.blocks).flatMap(\.inlines).compactMap { inline in
            if case .emoji(let emoji) = inline, seen.insert(emoji.url).inserted { emoji } else { nil }
        }
    }
}

extension Account {
    /// プロフィール画面に描いている`part`の文章。補足情報の番号が範囲の外ならnil。
    /// 補足情報は、値だけをコピーと翻訳に渡し、絵文字は名前と値の両方から集める。
    public func profileText(_ part: ProfileTextPart) -> ProfileText? {
        switch part {
        case .displayName:
            let name = RichText.plain(displayNameOrUsername, emojis: emojis)
            return ProfileText(text: name, emojiSources: [name])
        case .note:
            let note = RichText.html(note, emojis: emojis)
            return ProfileText(text: note, emojiSources: [note])
        case .field(let index):
            guard fields.indices.contains(index) else { return nil }
            let field = fields[index]
            let value = RichText.profileField(field.value, emojis: emojis)
            return ProfileText(text: value, emojiSources: [.plain(field.name, emojis: emojis), value])
        }
    }
}
