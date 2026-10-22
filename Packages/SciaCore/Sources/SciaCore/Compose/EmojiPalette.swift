public import Foundation

/// 絵文字のシートに並べる絵文字。サーバーのカスタム絵文字か、Unicodeの絵文字。
public enum PaletteEmoji: Hashable, Sendable {
    case custom(ServerEmoji)
    case standard(StandardEmoji)

    /// 最近使った絵文字として覚えるときの鍵。カスタム絵文字はショートコード、Unicodeの絵文字は絵文字そのもの。
    /// ショートコードは英数字と`_`だけなので、絵文字と取り違えない。
    public var recentKey: String {
        switch self {
        case .custom(let emoji): emoji.shortcode
        case .standard(let emoji): emoji.emoji
        }
    }
}

/// 投稿欄の絵文字のパレットに並べる、絵文字のまとまり。
public struct EmojiPaletteSection: Equatable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case recent
        /// カテゴリーの付いていない絵文字。
        case uncategorized
        case category(String)
        /// Unicodeの絵文字のまとまり。名前を持つ。
        case standard(String)
        /// 検索の結果。パレットで検索している間だけ、ほかのまとまりの代わりに出す。
        case searchResults
        /// カスタム絵文字の一覧を読んでいる間か、読めなかったとき、カスタム絵文字のまとまりの場所に置く状態の段。絵文字は持たない。
        case customEmojiStatus
    }

    public let kind: Kind
    public let emojis: [PaletteEmoji]
    public var id: Kind { kind }

    public init(kind: Kind, emojis: [PaletteEmoji]) {
        self.kind = kind
        self.emojis = emojis
    }
}

/// パレットに並べるものを決める。
public enum EmojiPalette {
    /// 最近使ったもの、カテゴリーのないもの、カテゴリーごと（名前の順）、Unicodeの絵文字のまとまりの順に分ける。中はサーバーやデータの順のまま。
    /// 一覧に出さないカスタム絵文字は除く。最近使ったもののうち、サーバーの一覧やUnicodeの絵文字の一覧にないものも除く。空のまとまりは作らない。
    /// カスタム絵文字を先に置くのは、サーバーにしかない絵文字を探しに来ることが多いため。カテゴリーのないものを先にするのは、Mastodonのweb UIと同じ。
    public static func sections(emojis: [ServerEmoji], standardGroups: [StandardEmojiGroup], recentKeys: [String], recentLimit: Int) -> [EmojiPaletteSection] {
        let visible = emojis.filter(\.visibleInPicker)
        var byKey: [String: PaletteEmoji] = [:]
        for group in standardGroups {
            for emoji in group.emojis {
                byKey[emoji.emoji] = .standard(emoji)
            }
        }
        for emoji in visible where byKey[emoji.shortcode] == nil {
            byKey[emoji.shortcode] = .custom(emoji)
        }
        let recent = recentKeys.compactMap { byKey[$0] }.prefix(max(recentLimit, 0))
        var sections: [EmojiPaletteSection] = []
        if !recent.isEmpty {
            sections.append(EmojiPaletteSection(kind: .recent, emojis: Array(recent)))
        }
        let uncategorized = visible.filter { ($0.category ?? "").isEmpty }
        if !uncategorized.isEmpty {
            sections.append(EmojiPaletteSection(kind: .uncategorized, emojis: uncategorized.map(PaletteEmoji.custom)))
        }
        let categorized = Dictionary(grouping: visible.filter { !($0.category ?? "").isEmpty }) { $0.category ?? "" }
        for name in categorized.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            sections.append(EmojiPaletteSection(kind: .category(name), emojis: (categorized[name] ?? []).map(PaletteEmoji.custom)))
        }
        for group in standardGroups where !group.emojis.isEmpty {
            sections.append(EmojiPaletteSection(kind: .standard(group.title), emojis: group.emojis.map(PaletteEmoji.standard)))
        }
        return sections
    }

    /// 検索の結果。カスタム絵文字のショートコードの一致を先に、Unicodeの絵文字の名前と言葉の一致を後に並べる。
    /// 検索欄は日本語の入力のまま打つので、全角の英数字は半角にそろえてからショートコードと比べる。
    public static func searchResults(matching query: String, emojis: [ServerEmoji], standardGroups: [StandardEmojiGroup], limit: Int) -> [PaletteEmoji] {
        let custom = EmojiCompletion.candidates(matching: query.precomposedStringWithCompatibilityMapping, in: emojis, limit: limit).map(PaletteEmoji.custom)
        let standard = StandardEmojiSearch.candidates(matching: query, in: standardGroups, limit: limit).map(PaletteEmoji.standard)
        return Array((custom + standard).prefix(max(limit, 0)))
    }
}

/// 最近使った絵文字を、サーバーごとに新しい順で覚える。カスタム絵文字はショートコード、Unicodeの絵文字は絵文字そのもので覚える（`PaletteEmoji.recentKey`）。
/// パレットと補完のどちらで入れても覚える。ショートコードはサーバーごとに違う絵文字を指すので、サーバーをまたいで混ぜない。
/// 同じサーバーを複数のウィンドウで開くと、ウィンドウごとに作られるので、手元に持たずに毎回UserDefaultsを読み書きする。
/// 持っていると、片方のウィンドウで選んだものを、もう片方が古い並びで上書きして消すため。
@MainActor
public final class RecentEmojis {
    private let defaults: UserDefaults
    private let key: String
    /// 覚えておく数。パレットに出す数はチューニングで、これより少なく選ぶ。
    public static let capacity = 100

    public init(defaults: UserDefaults, instance: URL) {
        self.defaults = defaults
        key = "compose.recentEmojis.\(instance.host() ?? instance.absoluteString)"
    }

    /// 新しい順の鍵。
    public var keys: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public func record(_ recentKey: String) {
        var keys = keys
        keys.removeAll { $0 == recentKey }
        keys.insert(recentKey, at: 0)
        defaults.set(Array(keys.prefix(Self.capacity)), forKey: key)
    }
}
