public import Foundation

/// 投稿に付いた、ひとつの絵文字のリアクション。Fedibirdの形で、決まりはdocs/emoji-reaction.mdにある。
public struct EmojiReaction: Codable, Hashable, Sendable {
    public let emoji: ReactionEmoji
    public private(set) var count: Int
    /// 自分がしたか。
    public private(set) var me: Bool

    public init(emoji: ReactionEmoji, count: Int, me: Bool) {
        self.emoji = emoji
        self.count = count
        self.me = me
    }

    private enum CodingKeys: String, CodingKey {
        case name, count, me, url, staticUrl, domain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try ReactionEmoji(from: decoder)
        count = try container.decodeCountIfPresent(forKey: .count) ?? 0
        me = container.decodeLossyIfPresent(Bool.self, forKey: .me) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        try emoji.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(me, forKey: .me)
    }

    /// 出す数。サーバーの数が自分のリアクションを含まない値で届いても、自分がしているなら1と出す。
    public var displayedCount: Int { me ? max(count, 1) : count }

    /// 数と自分がしたかを変えたもの。
    func setting(count: Int, me: Bool) -> EmojiReaction {
        var reaction = self
        reaction.count = count
        reaction.me = me
        return reaction
    }
}

/// リアクションに使う絵文字。Unicodeの絵文字か、カスタム絵文字。
/// 同じ絵文字かは、名前だけで見分ける。Fedibirdは投稿のリアクションを名前でまとめ（`Status#generate_grouped_emoji_reactions`）、取り消しも名前で照合するため、
/// 同じショートコードのカスタム絵文字は、サーバーが違っても1つのリアクションになる。まとめたものの`domain`は、先に使われたカスタム絵文字のものになる。
/// 画像のURLも、投稿のリアクションと絵文字の一覧のように、取り方で変わりうるため比べない。
public struct ReactionEmoji: Codable, Hashable, Sendable {
    /// Unicodeの絵文字か、カスタム絵文字のショートコード。ショートコードにはサーバーを含まない。
    public let name: String
    /// ほかのサーバーのカスタム絵文字なら、そのサーバー。Unicodeの絵文字と、ログインしているサーバーのカスタム絵文字ではnil。
    public let domain: String?
    /// カスタム絵文字の画像。Unicodeの絵文字ではnil。
    public let url: URL?
    public let staticUrl: URL?

    public init(name: String, domain: String? = nil, url: URL? = nil, staticUrl: URL? = nil) {
        self.name = name
        self.domain = domain
        self.url = url
        self.staticUrl = staticUrl
    }

    /// ログインしているサーバーのカスタム絵文字。
    public init(customEmoji: CustomEmoji) {
        self.init(name: customEmoji.shortcode, url: customEmoji.url, staticUrl: customEmoji.staticUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, staticUrl, domain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        domain = container.decodeLossyIfPresent(String.self, forKey: .domain).flatMap { $0.isEmpty ? nil : $0 }
        url = container.decodeURL(.media, forKey: .url)
        staticUrl = container.decodeURL(.media, forKey: .staticUrl)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(staticUrl, forKey: .staticUrl)
    }

    public static func == (lhs: ReactionEmoji, rhs: ReactionEmoji) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    /// APIのパスに入れる名前。ほかのサーバーのカスタム絵文字は、Fedibirdが`name@domain`で受け取る。
    public var requestName: String {
        domain.map { "\(name)@\($0)" } ?? name
    }

    /// カスタム絵文字か。画像のURLが読めなかったものも、ショートコードの形（英数字と`_`）ならカスタム絵文字とする。
    public var isCustom: Bool {
        url != nil || domain != nil || (!name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    }

    /// カスタム絵文字なら、本文の絵文字と同じ部品で描くための絵文字。
    public var customEmoji: CustomEmoji? {
        url.map { CustomEmoji(shortcode: name, url: $0, staticUrl: staticUrl ?? $0) }
    }
}

/// ストリーミングで届いた、投稿のリアクションの数の変化。
/// Fedibirdの`emoji_reaction`のイベントで、中身は`app/workers/publish_emoji_reaction_worker.rb`が作る。
public struct EmojiReactionUpdate: Decodable, Hashable, Sendable {
    public let statusID: Status.ID
    public let emoji: ReactionEmoji
    public let count: Int
    /// リアクションした人のID。
    public let accountIDs: [Account.ID]

    public init(statusID: Status.ID, emoji: ReactionEmoji, count: Int, accountIDs: [Account.ID]) {
        self.statusID = statusID
        self.emoji = emoji
        self.count = count
        self.accountIDs = accountIDs
    }

    private enum CodingKeys: String, CodingKey {
        case statusId, count, accountIds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusID = try container.decode(Status.ID.self, forKey: .statusId)
        emoji = try ReactionEmoji(from: decoder)
        count = try container.decodeCountIfPresent(forKey: .count) ?? 0
        accountIDs = (try? container.decodeIfPresent([Account.ID].self, forKey: .accountIds)) ?? []
    }
}

extension Status {
    /// `emoji`の自分のリアクションの有無を変えたもの。サーバーの結果を待たずに表示へ反映するために使う。
    /// 付けるときに、まだない絵文字なら末尾に足す。外して数が0になれば消す。
    public func settingEmojiReaction(_ emoji: ReactionEmoji, _ isOn: Bool) -> Status {
        var reactions = emojiReactions
        if let index = reactions.firstIndex(where: { $0.emoji == emoji }) {
            let reaction = reactions[index]
            guard reaction.me != isOn else { return self }
            let count = max(reaction.count + (isOn ? 1 : -1), 0)
            if count == 0, !isOn {
                reactions.remove(at: index)
            } else {
                reactions[index] = reaction.setting(count: count, me: isOn)
            }
        } else {
            guard isOn else { return self }
            reactions.append(EmojiReaction(emoji: emoji, count: 1, me: true))
        }
        return replacingEmojiReactions(reactions)
    }

    /// `emoji`のリアクションを`other`に揃えたもの。サーバーの応答のうち、その操作の結果だけを反映するために使う。
    public func adoptingEmojiReaction(_ emoji: ReactionEmoji, of other: Status) -> Status {
        var reactions = emojiReactions
        let adopted = other.emojiReactions.first { $0.emoji == emoji }
        if let index = reactions.firstIndex(where: { $0.emoji == emoji }) {
            if let adopted {
                reactions[index] = adopted
            } else {
                reactions.remove(at: index)
            }
        } else if let adopted {
            reactions.append(adopted)
        }
        return replacingEmojiReactions(reactions)
    }

    /// ストリーミングで届いた数を当てたもの。数は届いた値に置き換え、自分がしたかは`me`で決める。数が0で自分もしていなければ消し、手元にない絵文字なら末尾に足す。
    public func applyingEmojiReactionUpdate(_ update: EmojiReactionUpdate, me: Bool) -> Status {
        var reactions = emojiReactions
        let reaction = EmojiReaction(emoji: update.emoji, count: update.count, me: me)
        if let index = reactions.firstIndex(where: { $0.emoji == update.emoji }) {
            if reaction.displayedCount == 0 {
                reactions.remove(at: index)
            } else {
                reactions[index] = EmojiReaction(emoji: reactions[index].emoji, count: update.count, me: me)
            }
        } else if reaction.displayedCount > 0 {
            reactions.append(reaction)
        }
        return replacingEmojiReactions(reactions)
    }

    /// `emoji`の自分がしたかだけを変え、数は変えないもの。結果を待っている間にサーバーの数が届いたあとで、失敗して戻すときに使う。
    /// 数が自分のリアクションを含まない値（0）で、自分もしていなければ消す。
    public func settingEmojiReactionMe(_ emoji: ReactionEmoji, _ me: Bool) -> Status {
        guard let index = emojiReactions.firstIndex(where: { $0.emoji == emoji }) else { return self }
        var reactions = emojiReactions
        let reaction = reactions[index].setting(count: reactions[index].count, me: me)
        if reaction.displayedCount == 0 {
            reactions.remove(at: index)
        } else {
            reactions[index] = reaction
        }
        return replacingEmojiReactions(reactions)
    }

    /// `other`と、表示している投稿の絵文字のリアクションのほかは同じか。リアクションが同じならfalse。
    /// 一覧で、リアクションだけが変わった行を、ボタンの出入りと行の高さを動かして描き直すために使う（docs/emoji-reaction.md）。
    public func differsOnlyInEmojiReactions(from other: Status) -> Bool {
        guard displayed.emojiReactions != other.displayed.emojiReactions else { return false }
        return adoptingDisplayedEmojiReactions(of: other) == other
    }

    /// 表示している投稿の絵文字のリアクションを、`other`の表示している投稿のものにしたもの。
    private func adoptingDisplayedEmojiReactions(of other: Status) -> Status {
        let reactions = other.displayed.emojiReactions
        guard let reblog else { return replacingEmojiReactions(reactions) }
        return replacingReblog(with: reblog.replacingEmojiReactions(reactions))
    }

    /// 自分が`emoji`でリアクションしているか。
    public func hasEmojiReaction(_ emoji: ReactionEmoji) -> Bool {
        emojiReactions.contains { $0.emoji == emoji && $0.me }
    }
}
