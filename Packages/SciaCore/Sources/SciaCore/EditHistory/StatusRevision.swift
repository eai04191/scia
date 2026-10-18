public import Foundation

/// 編集された投稿の、ある時点の版。最初の投稿と今の投稿も1つの版として返る。
///
/// リンクカード、公開範囲、メンションとハッシュタグの一覧は、版ごとには返らない。
/// https://docs.joinmastodon.org/entities/StatusEdit/
public struct StatusRevision: Decodable, Equatable, Sendable {
    /// 本文のHTML。
    public let content: String
    /// 注意書き。HTMLではない文字列。
    public let spoilerText: String
    public let sensitive: Bool
    /// この版を投稿した日時。最初の版では投稿した日時、ほかの版では編集した日時。
    public let createdAt: Date
    public let account: Account
    /// この版の添付ファイル。同じファイルは版をまたいでも同じIDで、代替テキストだけが版ごとに残る。
    public let mediaAttachments: [MediaAttachment]
    public let emojis: [CustomEmoji]
    /// 投票の選択肢。投票がなければnil。票の数は版ごとには残らない。
    public let pollOptions: [String]?

    public init(
        content: String,
        spoilerText: String = "",
        sensitive: Bool = false,
        createdAt: Date,
        account: Account,
        mediaAttachments: [MediaAttachment] = [],
        emojis: [CustomEmoji] = [],
        pollOptions: [String]? = nil
    ) {
        self.content = content
        self.spoilerText = spoilerText
        self.sensitive = sensitive
        self.createdAt = createdAt
        self.account = account
        self.mediaAttachments = mediaAttachments
        self.emojis = emojis
        self.pollOptions = pollOptions
    }

    /// `Status`と同じく、配列はサーバーによって空や欠落で返るため空にし、投票は読めなければ記録してnilにする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        spoilerText = try container.decodeIfPresent(String.self, forKey: .spoilerText) ?? ""
        sensitive = try container.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        account = try container.decode(Account.self, forKey: .account)
        mediaAttachments = try container.decodeLossyArray(MediaAttachment.self, forKey: .mediaAttachments)
        emojis = try container.decodeLossyArray(CustomEmoji.self, forKey: .emojis)
        pollOptions = container.decodeLossyIfPresent(RevisionPoll.self, forKey: .poll)?.options.map(\.title)
    }

    private enum CodingKeys: String, CodingKey {
        case content, spoilerText, sensitive, createdAt, account, mediaAttachments, emojis, poll
    }

    private struct RevisionPoll: Decodable {
        struct Option: Decodable {
            let title: String
        }

        let options: [Option]
    }
}
