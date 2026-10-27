public import Foundation

/// 予約した投稿。予約の時刻にサーバーが投稿する。決まりはdocs/compose.mdの「予約投稿」とdocs/tabs.mdの「予約投稿」にある。
/// https://docs.joinmastodon.org/entities/ScheduledStatus/
public struct ScheduledStatus: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let scheduledAt: Date
    public let params: Params
    /// 投稿するときに付ける添付。この順で投稿に並ぶ。
    public let mediaAttachments: [MediaAttachment]

    public init(id: String, scheduledAt: Date, params: Params, mediaAttachments: [MediaAttachment] = []) {
        self.id = id
        self.scheduledAt = scheduledAt
        self.params = params
        self.mediaAttachments = mediaAttachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, scheduledAt, params, mediaAttachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        scheduledAt = try container.decode(Date.self, forKey: .scheduledAt)
        params = try container.decode(Params.self, forKey: .params)
        // サーバーは添付をデータベースの順で返すが、投稿するときは`params.media_ids`の順に並べる。並べ替えた予約の順を保つため、その順にそろえる。
        // `media_ids`にない添付は、返った順のまま後ろに置く。
        let attachments = try container.decodeLossyArray(MediaAttachment.self, forKey: .mediaAttachments)
        let order = Dictionary(params.mediaIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        mediaAttachments = attachments.enumerated().sorted { lhs, rhs in
            (order[lhs.element.id] ?? order.count + lhs.offset, lhs.offset) < (order[rhs.element.id] ?? order.count + rhs.offset, rhs.offset)
        }.map(\.element)
    }

    /// 予約したときに送った内容。サーバーは送られたフォームの値をそのまま持つため、真偽値や数も文字列で返ることがある。
    /// 文書では`in_reply_to_id`は数、`quoted_status_id`は文字列なので、どれも両方の形で読む。
    public struct Params: Decodable, Hashable, Sendable {
        /// 書いたときのソースのままの本文。HTMLではない。
        public let text: String
        /// 空なら注意書きなし。
        public let spoilerText: String
        public let sensitive: Bool
        /// 送らなかったときはnilで、アカウントの既定の公開範囲で投稿される。
        public let visibility: Status.Visibility?
        public let inReplyToID: String?
        public let quotedStatusID: String?
        public let poll: PollDraft?
        /// 投稿するときに付ける添付のID。この順で投稿に並ぶ。
        public let mediaIDs: [String]

        public init(
            text: String,
            spoilerText: String = "",
            sensitive: Bool = false,
            visibility: Status.Visibility? = nil,
            inReplyToID: String? = nil,
            quotedStatusID: String? = nil,
            poll: PollDraft? = nil,
            mediaIDs: [String] = []
        ) {
            self.text = text
            self.spoilerText = spoilerText
            self.sensitive = sensitive
            self.visibility = visibility
            self.inReplyToID = inReplyToID
            self.quotedStatusID = quotedStatusID
            self.poll = poll
            self.mediaIDs = mediaIDs
        }

        private enum CodingKeys: String, CodingKey {
            case text, spoilerText, sensitive, visibility, poll
            case mediaIDs = "mediaIds"
            case inReplyToID = "inReplyToId"
            case quotedStatusID = "quotedStatusId"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // 添付だけの予約では本文がnullになりうる。
            text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
            spoilerText = (try? container.decodeIfPresent(String.self, forKey: .spoilerText)) ?? ""
            sensitive = container.decodeFlexibleBool(forKey: .sensitive) ?? false
            visibility = (try? container.decodeIfPresent(String.self, forKey: .visibility)).flatMap { $0 }.map(Status.Visibility.init(rawValue:))
            inReplyToID = try? container.decodeFlexibleString(forKey: .inReplyToID)
            quotedStatusID = try? container.decodeFlexibleString(forKey: .quotedStatusID)
            poll = container.decodeLossyIfPresent(ScheduledPoll.self, forKey: .poll)?.draft
            mediaIDs = (try? container.decodeIfPresent([String].self, forKey: .mediaIDs)) ?? []
        }
    }
}

/// 予約に付けた投票。`PollDraft`に直して持つ。
private struct ScheduledPoll: Decodable {
    let draft: PollDraft

    private enum CodingKeys: String, CodingKey {
        case options, expiresIn, multiple, hideTotals
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let options = try container.decode([String].self, forKey: .options)
        guard let expiresIn = container.decodeFlexibleInt(forKey: .expiresIn) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresIn, in: container, debugDescription: "投票の締め切りまでの秒数がありません")
        }
        draft = PollDraft(
            options: options,
            multiple: container.decodeFlexibleBool(forKey: .multiple) ?? false,
            hidesTotals: container.decodeFlexibleBool(forKey: .hideTotals) ?? false,
            expiresIn: expiresIn
        )
    }
}

private extension KeyedDecodingContainer {
    /// 文字列か整数で返るIDを、文字列で読む。項目がない、またはnullなら投げる。
    func decodeFlexibleString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        return String(try decode(Int64.self, forKey: key))
    }

    /// 真偽値か、フォームの値の文字列（`"true"`、`"1"`など）を読む。読めなければnil。
    func decodeFlexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        guard let string = try? decode(String.self, forKey: key) else { return nil }
        switch string.lowercased() {
        case "true", "1", "on": return true
        case "false", "0", "off", "": return false
        default: return nil
        }
    }

    /// 件数を、整数か整数の文字列で読む。範囲の外の値は`ServerCount`の範囲に収める。読めなければnil。
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeCount(forKey: key) {
            return value
        }
        return (try? decode(String.self, forKey: key)).flatMap { Int($0) }.map(ServerCount.clamped)
    }
}
