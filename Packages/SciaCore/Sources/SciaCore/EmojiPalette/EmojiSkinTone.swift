/// 絵文字の肌の色。Unicodeの肌の色の修飾（U+1F3FB〜U+1F3FF）の明るいほうからの順。決まりはdocs/compose.mdの「絵文字の肌の色」にある。
public enum EmojiSkinTone: Int, CaseIterable, Hashable, Sendable {
    /// 肌の色を付けない。絵文字の書体の既定の色（黄色）で描かれる。
    case none
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    /// メニューの項目の名前。肌の色の名前は、絵文字の名前と同じくCLDRの日本語の名前にする。
    public var title: String {
        switch self {
        case .none: "肌の色なし"
        case .light: "薄い肌色"
        case .mediumLight: "やや薄い肌色"
        case .medium: "中間の肌色"
        case .mediumDark: "やや濃い肌色"
        case .dark: "濃い肌色"
        }
    }

    /// 肌の色を付けた並びのリストでの位置。付けないならnil。
    var variantIndex: Int? {
        self == .none ? nil : rawValue - 1
    }
}

/// 絵文字1つの、肌の色を付けた並び。
public enum EmojiSkinToneVariants: Hashable, Sendable {
    /// 1人の絵文字。明るいほうから5つ。
    case single([String])
    /// 2人の絵文字（握手、手をつなぐ人など）。1人目の色を行、2人目の色を列にして、行ごとに25個。
    /// 片方だけに肌の色を付けた並びはUnicodeにないので、付けるなら2人ともに付ける。
    case pair([String])

    /// データの並びから作る。5個なら1人、25個なら2人。ほかの数は、作りの誤りなので読まない。
    init?(_ variants: [String]) {
        switch variants.count {
        case 5: self = .single(variants)
        case 25: self = .pair(variants)
        default: return nil
        }
    }

    /// 2人の絵文字か。
    public var isPair: Bool {
        if case .pair = self { true } else { false }
    }

    /// 肌の色を付けた並びすべて。
    var all: [String] {
        switch self {
        case .single(let variants), .pair(let variants): variants
        }
    }
}

extension StandardEmoji {
    /// 肌の色を変えた絵文字。2人の絵文字は、2人とも同じ色にする。肌の色を変えられない絵文字はそのまま返す。
    public func withSkinTone(_ tone: EmojiSkinTone) -> StandardEmoji {
        withSkinTones(tone, tone)
    }

    /// 2人の絵文字の、2人それぞれの肌の色を変えた絵文字。どちらかが肌の色を付けないなら、2人とも付けない。
    /// 1人の絵文字では、`first`の色にする。
    public func withSkinTones(_ first: EmojiSkinTone, _ second: EmojiSkinTone) -> StandardEmoji {
        guard let skinTones else { return self }
        switch skinTones {
        case .single(let variants):
            return replacingEmoji(first.variantIndex.map { variants[$0] } ?? untonedEmoji)
        case .pair(let variants):
            guard let first = first.variantIndex, let second = second.variantIndex else { return replacingEmoji(untonedEmoji) }
            return replacingEmoji(variants[first * 5 + second])
        }
    }

    /// 今の肌の色。2人の絵文字は、1人目と2人目の色。付けていなければ、どちらも`.none`。
    public var currentSkinTones: (first: EmojiSkinTone, second: EmojiSkinTone) {
        guard let skinTones, let index = skinTones.all.firstIndex(of: emoji) else { return (.none, .none) }
        switch skinTones {
        case .single:
            let tone = EmojiSkinTone(rawValue: index + 1) ?? .none
            return (tone, tone)
        case .pair:
            return (EmojiSkinTone(rawValue: index / 5 + 1) ?? .none, EmojiSkinTone(rawValue: index % 5 + 1) ?? .none)
        }
    }

    /// 付けている肌の色の名前。読み上げで、同じ絵文字の色違いを区別するのに使う。付けていなければnil。
    /// 2人の絵文字で2人の色が違うときは、左の人、右の人の順に並べる。
    public var skinToneDescription: String? {
        let tones = currentSkinTones
        guard tones.first != .none else { return nil }
        return tones.first == tones.second ? tones.first.title : "\(tones.first.title)、\(tones.second.title)"
    }

    /// 肌の色を変えられないものとして扱う絵文字。端末が肌の色を付けた並びを描けないときに使う。
    public func removingSkinTones() -> StandardEmoji {
        StandardEmoji(emoji: untonedEmoji, name: name, englishName: englishName, keywords: keywords, shortcodes: shortcodes, version: version)
    }

    /// 2人の絵文字を、2人同じ色だけを選べる絵文字として扱うもの。端末が2人の色の違う並びを描けないときに使う。
    public func limitingSkinTonesToSameForBoth() -> StandardEmoji {
        guard case .pair(let variants) = skinTones else { return self }
        return StandardEmoji(emoji: untonedEmoji, name: name, englishName: englishName, keywords: keywords, shortcodes: shortcodes, version: version, skinTones: .single((0..<5).map { variants[$0 * 5 + $0] }))
    }

    /// 肌の色を付けた並びを端末が描けるかを確かめるための見本。`same`は1人の絵文字か、2人とも同じ色の並び。`mixed`は2人の色が違う並びで、1人の絵文字ではnil。
    /// 2人の色が違う並びは、同じ色の並びと別の文字で組まれることがあり（握手の🤝🏻に対する🫱🏻‍🫲🏼）、描けるかが分かれるため、別々に確かめる。
    public var skinToneSamples: (same: String, mixed: String?)? {
        switch skinTones {
        case .single(let variants): (variants[0], nil)
        case .pair(let variants): (variants[0], variants[1])
        case nil: nil
        }
    }

    /// 肌の色を付ける前の絵文字と、肌の色を付けた並びすべて。最近使った絵文字を、使ったときの色のまま引くのに使う。
    var allSkinToneForms: [StandardEmoji] {
        guard let skinTones else { return [] }
        return ([untonedEmoji] + skinTones.all).map(replacingEmoji)
    }
}

extension [StandardEmojiGroup] {
    /// 肌の色を変えられる絵文字を、`tone`の色にしたリスト。
    public func withSkinTone(_ tone: EmojiSkinTone) -> [StandardEmojiGroup] {
        guard tone != .none else { return self }
        return map { group in StandardEmojiGroup(title: group.title, emojis: group.emojis.map { $0.withSkinTone(tone) }) }
    }
}
