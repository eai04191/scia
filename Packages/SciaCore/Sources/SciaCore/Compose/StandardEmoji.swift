import Foundation

/// Unicodeの絵文字1つ。投稿欄の絵文字のシートで、カスタム絵文字の後ろに並べる。
/// データは`Tools/build-emoji-data.py`で、Unicodeの絵文字の一覧（emoji-test.txt）とCLDRの絵文字の注釈から作る。
public struct StandardEmoji: Hashable, Sendable, Decodable {
    /// 絵文字そのもの。本文にはこの文字をそのまま入れる。
    public let emoji: String
    /// 日本語の名前。CLDRの読み上げの名前。
    public let name: String
    /// 検索に使う、日本語と英語の言葉。
    public let keywords: [String]
    /// その絵文字が入ったUnicodeの絵文字の版（「15.1」など）。
    public let version: String

    public init(emoji: String, name: String, keywords: [String], version: String) {
        self.emoji = emoji
        self.name = name
        self.keywords = keywords
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case emoji = "e"
        case name = "n"
        case keywords = "k"
        case version = "v"
    }
}

/// Unicodeの絵文字のまとまり（顔と感情、人と体など）。並びはemoji-test.txtの順で、iOSの絵文字キーボードとほぼ同じ。
public struct StandardEmojiGroup: Hashable, Sendable, Decodable {
    public let title: String
    public let emojis: [StandardEmoji]

    public init(title: String, emojis: [StandardEmoji]) {
        self.title = title
        self.emojis = emojis
    }
}

/// アプリに入れたUnicodeの絵文字の一覧。
public enum StandardEmojiCatalog {
    private struct File: Decodable {
        let groups: [StandardEmojiGroup]
    }

    /// 一覧。読めなければ空にする。データはアプリに入れたものなので、読めないのは作りの誤りで、テストで確かめる。
    public static let groups: [StandardEmojiGroup] = {
        guard let url = Bundle.module.url(forResource: "standard-emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.groups
    }()
}

/// Unicodeの絵文字を、CLDRの名前と言葉の文字列一致で探す。
///
/// ひらがなとカタカナ、全角と半角、大文字と小文字は区別しない。「ねこ」で「ネコ」や「猫」の言葉を持つ絵文字が見つかるよう、言葉ごとに比べる。
/// 言葉と一致するもの、言葉（英語は言葉の中の単語）が語で始まるもの、言葉が語を含むものの順に並べ、それぞれの中は一覧の順のままにする。
/// 語を含むものは、語に英数字以外が入るときだけ探す。英語で途中の一致まで拾うと、「cat」で「education」や「location」が当たるため。
/// 日本語は単語の区切りがないので、「ねこ」で「黒ねこ」のような途中の一致も拾う。
public enum StandardEmojiSearch {
    public static func candidates(matching query: String, in groups: [StandardEmojiGroup], limit: Int) -> [StandardEmoji] {
        let query = normalize(query)
        guard !query.isEmpty else { return [] }
        var exact: [StandardEmoji] = []
        var prefixed: [StandardEmoji] = []
        var contained: [StandardEmoji] = []
        let matchesInside = !query.allSatisfy(\.isASCII)
        for emoji in groups.lazy.flatMap(\.emojis) {
            let words = ([emoji.name] + emoji.keywords).map(normalize)
            if words.contains(query) {
                exact.append(emoji)
            } else if words.contains(where: { word in
                word.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(query) } || word.hasPrefix(query)
            }) {
                prefixed.append(emoji)
            } else if matchesInside, words.contains(where: { $0.contains(query) }) {
                contained.append(emoji)
            }
        }
        return Array((exact + prefixed + contained).prefix(max(limit, 0)))
    }

    /// 比べる前にそろえる。全角と半角は互換分解でそろえ、カタカナはひらがなにし、大文字は小文字にする。前後の空白は除く。
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let hiragana = folded.applyingTransform(.hiraganaToKatakana, reverse: true) ?? folded
        return hiragana.trimmingCharacters(in: .whitespaces)
    }
}
