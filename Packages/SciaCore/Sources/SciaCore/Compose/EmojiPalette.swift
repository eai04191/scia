public import Foundation

/// 絵文字のシートに並べる絵文字。サーバーのカスタム絵文字か、Unicodeの絵文字。
public enum PaletteEmoji: Hashable, Sendable {
    case custom(ServerEmoji)
    case standard(StandardEmoji)

    /// 最近使った絵文字として覚えるときのキー。カスタム絵文字はショートコード、Unicodeの絵文字は絵文字そのもの。
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
        /// 個人セットのカテゴリー。名前は同じものを作れるので、IDでも見分ける。
        case personal(id: String, name: String)
        /// カテゴリーの付いていない絵文字。
        case uncategorized
        case category(String)
        /// Unicodeの絵文字のまとまり。名前を持つ。
        case standard(String)
        /// 検索の結果。パレットで検索している間だけ、ほかのまとまりの代わりに出す。
        case searchResults
        /// カスタム絵文字のリストを読んでいる間か、読めなかったとき、カスタム絵文字のまとまりの場所に置く状態の段。絵文字は持たない。
        case customEmojiStatus

        /// まとまりの見出し。
        public var title: String {
            switch self {
            case .recent: "最近使った絵文字"
            case .personal(_, let name): name
            case .uncategorized: "カスタム"
            case .category(let name): name
            case .standard(let name): name
            case .searchResults: "検索の結果"
            case .customEmojiStatus: "カスタム"
            }
        }
    }

    public let kind: Kind
    public let emojis: [PaletteEmoji]
    /// 個人セットのカテゴリーの見出し。まとまりのボタンのアイコンにする。ほかのまとまりではnil。
    public let heading: PersonalEmojiSet.Heading?
    public var id: Kind { kind }

    public init(kind: Kind, emojis: [PaletteEmoji], heading: PersonalEmojiSet.Heading? = nil) {
        self.kind = kind
        self.emojis = emojis
        self.heading = heading
    }
}

/// パレットに並べるものを決める。
public enum EmojiPalette {
    /// 最近使ったもの、個人セットのカテゴリーごと（サーバーが返す順）、カテゴリーのないもの、カテゴリーごと（名前の順）、Unicodeの絵文字のまとまりの順に分ける。
    /// 最近使ったものは新しい順、個人セットの中はサーバーが返す順、カスタム絵文字のまとまりの中はショートコードを小文字にそろえて比べた順、Unicodeの絵文字はデータの順。
    /// ピッカーに出さないカスタム絵文字は除く。個人セットには、ピッカーに出さないカスタム絵文字も、肌の色を付けたUnicodeの絵文字も入るので、そのまま並べる。
    /// 最近使ったもののうち、サーバーの絵文字のリストにも、Unicodeの絵文字のリストにも、個人セットにもないものは除く。空のまとまりは作らない。
    /// カスタム絵文字を先に置くのは、サーバーにしかない絵文字を探しに来ることが多いため。カテゴリーのないものを先にすることと、まとまりの中の順は、Mastodonのweb UIと同じ。
    public static func sections(emojis: [ServerEmoji], personal: PersonalEmojiSet? = nil, standardGroups: [StandardEmojiGroup], recentKeys: [String], recentLimit: Int) -> [EmojiPaletteSection] {
        let visible = emojis.filter(\.visibleInPicker).sorted { $0.shortcode.lowercased() < $1.shortcode.lowercased() }
        var byKey: [String: PaletteEmoji] = [:]
        for group in standardGroups {
            for emoji in group.emojis {
                byKey[emoji.emoji] = .standard(emoji)
            }
        }
        for emoji in visible where byKey[emoji.shortcode] == nil {
            byKey[emoji.shortcode] = .custom(emoji)
        }
        // リストは既定の肌の色で並べているので、ほかの色の絵文字（個人セットの絵文字、ほかの色で使った最近のもの）は、肌の色の並びから引く。
        // 引いたものは、文字はそのままで、肌の色を変えられることを持つ。引く表を作るのは、リストにない絵文字があるときだけにする。
        var toned: [String: PaletteEmoji]?
        func tonedForm(_ key: String) -> PaletteEmoji? {
            if toned == nil {
                toned = Dictionary(standardGroups.flatMap(\.emojis).flatMap(\.allSkinToneForms).map { ($0.emoji, PaletteEmoji.standard($0)) }) { first, _ in first }
            }
            return toned?[key]
        }
        // Unicodeの絵文字のリストにある絵文字は、そのリストのものにそろえる。同じ絵文字が、個人セットとUnicodeの絵文字のまとまりとで別のものにならないようにするため。
        // カスタム絵文字は、個人セットの応答の画像のまま並べる。端末に残した古いリストの画像に替えないため。
        let personalCategories = (personal?.categories ?? []).map { category in
            (category, category.entries.map { entry in
                guard case .standard = entry.emoji, let listed = byKey[entry.emoji.recentKey] ?? tonedForm(entry.emoji.recentKey) else { return entry.emoji }
                return listed
            })
        }
        // 最近使ったものでも、個人セットのカスタム絵文字は個人セットの応答の画像で出す。同じ絵文字が、まとまりによって別の画像にならないようにするため。
        for (_, emojis) in personalCategories {
            for emoji in emojis {
                if case .custom = emoji {
                    byKey[emoji.recentKey] = emoji
                } else if byKey[emoji.recentKey] == nil {
                    byKey[emoji.recentKey] = emoji
                }
            }
        }
        // 最近使ったものは、使ったときの肌の色のまま出す。
        let recent = recentKeys.compactMap { byKey[$0] ?? tonedForm($0) }.prefix(max(recentLimit, 0))
        var sections: [EmojiPaletteSection] = []
        if !recent.isEmpty {
            sections.append(EmojiPaletteSection(kind: .recent, emojis: Array(recent)))
        }
        var personalIDs: Set<String> = []
        for (category, emojis) in personalCategories where !emojis.isEmpty && personalIDs.insert(category.id).inserted {
            // 見出しの絵文字も、まとまりの中の絵文字と同じものにそろえる。
            let heading: PersonalEmojiSet.Heading = if case .emoji(let emoji) = category.heading, let listed = emojis.first(where: { $0.recentKey == emoji.recentKey }) {
                .emoji(listed)
            } else {
                category.heading
            }
            sections.append(EmojiPaletteSection(kind: .personal(id: category.id, name: category.name), emojis: emojis, heading: heading))
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

    /// 検索の結果。個人セットのうち検索の語（ショートコード、別名、読みなど）に検索語を含むものを先に、カスタム絵文字のショートコードの一致、Unicodeの絵文字の名前と言葉の一致の順に並べる。
    /// 検索欄は日本語の入力のまま打つので、全角の英数字は半角にそろえてからショートコードと比べる。
    public static func searchResults(matching query: String, emojis: [ServerEmoji], personal: PersonalEmojiSet? = nil, standardGroups: [StandardEmojiGroup], limit: Int) -> [PaletteEmoji] {
        let normalized = query.precomposedStringWithCompatibilityMapping
        let custom = EmojiCompletion.candidates(matching: normalized, in: emojis, limit: limit).map(PaletteEmoji.custom)
        let standard = StandardEmojiSearch.candidates(matching: query, in: standardGroups, limit: limit).map(PaletteEmoji.standard)
        var seen: Set<String> = []
        let results = (personalMatches(query, in: personal) + custom + standard).filter { seen.insert($0.recentKey).inserted }
        return Array(results.prefix(max(limit, 0)))
    }

    /// ひらがなとカタカナ、全角と半角、大文字と小文字は、Unicodeの絵文字の検索と同じく区別しない。
    private static func personalMatches(_ query: String, in personal: PersonalEmojiSet?) -> [PaletteEmoji] {
        let needle = StandardEmojiSearch.normalize(query)
        guard let personal, !needle.isEmpty else { return [] }
        return personal.categories.flatMap(\.entries).filter { entry in
            entry.searchTerms.contains { StandardEmojiSearch.normalize($0).contains(needle) }
        }.map(\.emoji)
    }
}

/// パレットのマスに絵文字を並べる。横長のカスタム絵文字は、高さをあまり縮めずに描けるだけのマスを横に使う。
/// 絵を描く枠の余白はマスの高さから決めるので、マスの数は縦横比だけで決まり、マスの大きさによらない。
public enum EmojiPaletteGrid {
    /// 絵を描く枠の上下左右の余白の、マスの高さに対する割合。
    public static let imageInsetFraction = 0.15

    /// 絵文字1つを置く場所。`span`は横に使うマスの数。
    public struct Placement: Equatable, Sendable {
        public let row: Int
        public let column: Int
        public let span: Int

        public init(row: Int, column: Int, span: Int) {
            self.row = row
            self.column = column
            self.span = span
        }
    }

    /// 縦横比（幅/高さ）の絵を、枠の高さの`minimumHeightFraction`以上で描ける一番少ないマスの数。
    /// `maxSpan`マスでも足りなければ`maxSpan`マスにし、縮めて描く。縦横比が分からないか、1マスで足りるなら1マス。
    public static func span(aspectRatio: Double?, maxSpan: Int, minimumHeightFraction: Double) -> Int {
        let limit = max(maxSpan, 1)
        guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else { return 1 }
        return (1...limit).first { frameAspectRatio(span: $0) / aspectRatio >= minimumHeightFraction } ?? limit
    }

    /// `span`マスの、絵を描く枠の縦横比。
    static func frameAspectRatio(span: Int) -> Double {
        (Double(span) - imageInsetFraction * 2) / (1 - imageInsetFraction * 2)
    }

    /// 左から右、上から下へ詰める。行の残りに入らない絵文字は、次の行の先頭に送る。並びの順は変えない。
    /// `columns`より多いマスの絵文字は、`columns`マスにする。
    public static func place(spans: [Int], columns: Int) -> [Placement] {
        let columns = max(columns, 1)
        var row = 0
        var column = 0
        return spans.map { requested in
            let span = min(max(requested, 1), columns)
            if column + span > columns {
                row += 1
                column = 0
            }
            defer { column += span }
            return Placement(row: row, column: column, span: span)
        }
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
        key = AccountScopedDefaults.key("recentEmojis", server: instance)
    }

    /// 新しい順のキー。
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
