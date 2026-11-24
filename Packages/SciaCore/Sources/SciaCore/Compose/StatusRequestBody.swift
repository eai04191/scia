import Foundation

/// 投稿、予約、編集で送る本文。JSONで送る。
/// form形式の`media_ids[]`や`poll[options][]`を読まずに捨てるサーバー（Sharkey、26.11.1までのCatodon）があるため。docs/server-compatibility.md#media-ids-form
/// https://docs.joinmastodon.org/methods/statuses/#create
struct StatusRequestBody: Encodable, Equatable {
    struct MediaAttribute: Encodable, Equatable {
        let id: String
        let description: String
    }

    struct Poll: Encodable, Equatable {
        let options: [String]
        let expiresIn: Int
        let multiple: Bool
        let hideTotals: Bool

        private enum CodingKeys: String, CodingKey {
            case options
            case expiresIn = "expires_in"
            case multiple
            case hideTotals = "hide_totals"
        }
    }

    /// 引用元のIDと、それを入れるパラメーターの名前。名前はサーバーの引用の決まりで変わる。
    struct Quote: Equatable {
        let parameter: String
        let statusID: String
    }

    var status: String
    var spoilerText: String?
    var sensitive: Bool
    var visibility: Status.Visibility?
    var inReplyToID: String?
    var quote: Quote?
    var language: String?
    var quoteApprovalPolicy: QuotePolicy?
    var mediaIDs: [String]?
    var mediaAttributes: [MediaAttribute]?
    var poll: Poll?
    var scheduledAt: Date?

    init(
        status: String,
        spoilerText: String? = nil,
        sensitive: Bool,
        visibility: Status.Visibility? = nil,
        inReplyToID: String? = nil,
        quote: Quote? = nil,
        language: String? = nil,
        quoteApprovalPolicy: QuotePolicy? = nil,
        mediaIDs: [String]? = nil,
        mediaAttributes: [MediaAttribute]? = nil,
        poll: Poll? = nil,
        scheduledAt: Date? = nil
    ) {
        self.status = status
        self.spoilerText = spoilerText
        self.sensitive = sensitive
        self.visibility = visibility
        self.inReplyToID = inReplyToID
        self.quote = quote
        self.language = language
        self.quoteApprovalPolicy = quoteApprovalPolicy
        self.mediaIDs = mediaIDs
        self.mediaAttributes = mediaAttributes
        self.poll = poll
        self.scheduledAt = scheduledAt
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(status, forKey: Key("status"))
        try container.encodeIfPresent(spoilerText, forKey: Key("spoiler_text"))
        try container.encode(sensitive, forKey: Key("sensitive"))
        try container.encodeIfPresent(visibility?.rawValue, forKey: Key("visibility"))
        try container.encodeIfPresent(inReplyToID, forKey: Key("in_reply_to_id"))
        if let quote {
            try container.encode(quote.statusID, forKey: Key(quote.parameter))
        }
        try container.encodeIfPresent(language, forKey: Key("language"))
        try container.encodeIfPresent(quoteApprovalPolicy?.rawValue, forKey: Key("quote_approval_policy"))
        try container.encodeIfPresent(mediaIDs, forKey: Key("media_ids"))
        try container.encodeIfPresent(mediaAttributes, forKey: Key("media_attributes"))
        try container.encodeIfPresent(poll, forKey: Key("poll"))
        try container.encodeIfPresent(scheduledAt?.formatted(.iso8601), forKey: Key("scheduled_at"))
    }

    /// キーの順を決めて書き出す。
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
