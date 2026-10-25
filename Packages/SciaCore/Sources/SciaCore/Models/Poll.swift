public import Foundation

/// 投稿に付いた投票。
/// https://docs.joinmastodon.org/entities/Poll/
public struct Poll: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// 締め切り。締め切りのない投票ではnil。
    public let expiresAt: Date?
    public let expired: Bool
    /// 複数の選択肢を選べる。
    public let multiple: Bool
    /// 票の数。複数選べる投票では、1人が入れた票をそれぞれ数える。
    public let votesCount: Int
    /// 投票した人の数。複数選べない投票ではnil。
    public let votersCount: Int?
    public let options: [Option]
    /// 選択肢で使われるカスタム絵文字。
    public let emojis: [CustomEmoji]
    /// 自分が投票している。ログインせずに読んだときは返らないため、無ければfalseにする。
    public let voted: Bool
    /// 自分が選んだ選択肢の、`options`での位置。ログインせずに読んだときは返らないため、無ければ空にする。
    public let ownVotes: [Int]

    public init(
        id: String,
        expiresAt: Date?,
        expired: Bool,
        multiple: Bool,
        votesCount: Int,
        votersCount: Int? = nil,
        options: [Option],
        emojis: [CustomEmoji] = [],
        voted: Bool = false,
        ownVotes: [Int] = []
    ) {
        self.id = id
        self.expiresAt = expiresAt
        self.expired = expired
        self.multiple = multiple
        self.votesCount = votesCount
        self.votersCount = votersCount
        self.options = options
        self.emojis = emojis
        self.voted = voted
        self.ownVotes = ownVotes
    }

    /// 選択肢は要素ごとには読まない。投票と自分の選んだものは選択肢の位置で表すため、1つでも外すと位置がずれ、別の選択肢に票を入れてしまう。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        expired = try container.decode(Bool.self, forKey: .expired)
        multiple = try container.decode(Bool.self, forKey: .multiple)
        votesCount = try container.decodeCount(forKey: .votesCount)
        votersCount = try container.decodeCountIfPresent(forKey: .votersCount)
        options = try container.decode([Option].self, forKey: .options)
        emojis = try container.decodeLossyArray(CustomEmoji.self, forKey: .emojis)
        voted = try container.decodeIfPresent(Bool.self, forKey: .voted) ?? false
        ownVotes = try container.decodeIfPresent([Int].self, forKey: .ownVotes) ?? []
    }

    /// https://docs.joinmastodon.org/entities/Poll/#Option
    public struct Option: Codable, Hashable, Sendable {
        public let title: String
        /// この選択肢の票の数。結果をまだ公開していない投票ではnil。
        public let votesCount: Int?

        public init(title: String, votesCount: Int?) {
            self.title = title
            self.votesCount = votesCount
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            votesCount = try container.decodeCountIfPresent(forKey: .votesCount)
        }
    }
}
