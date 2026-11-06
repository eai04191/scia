public import Foundation

/// ストリーミングAPIから届くイベントのうち、Sciaが扱うもの。
/// https://docs.joinmastodon.org/methods/streaming/#events
public enum StreamingEvent: Sendable, Equatable {
    /// タイムラインに新しい投稿が現れた。
    case update(Status)
    /// 投稿が編集された。
    case statusUpdate(Status)
    /// 投稿が削除された。
    case delete(statusID: String)
    /// 通知が届いた。
    case notification(MastodonNotification)
    /// キーワードフィルターが変わった。
    case filtersChanged
    /// 受け入れた保留中の通知を、サーバーが通知のタイムラインに戻し終えた。
    case notificationsMerged
    /// サーバーのお知らせが出た、または編集された。中身には、自分が既読にしたかと、自分がどのリアクションをしたかが入っていない。
    case announcement(Announcement)
    /// お知らせのリアクションの数が変わった。
    case announcementReaction(AnnouncementReactionUpdate)
    /// お知らせが取り下げられた。
    case announcementDelete(announcementID: Announcement.ID)
    /// 投稿の絵文字のリアクションの数が変わった。Fedibirdの拡張で、`user`のストリームに届く。
    case emojiReaction(EmojiReactionUpdate)
    /// まだ扱っていない種類のイベント。
    case unhandled(name: String)
}

/// 届いたイベントと、それがどの購読のものか。
public struct StreamingMessage: Sendable, Equatable {
    /// 購読のストリーム。`["user"]`や`["list", "<id>"]`。
    public let stream: [String]
    public let event: StreamingEvent

    public init(stream: [String], event: StreamingEvent) {
        self.stream = stream
        self.event = event
    }
}

/// ストリーミングサーバーが接続の中で返したエラー。
public struct StreamingServerError: Error, Equatable, LocalizedError {
    public let message: String
    public let status: Int?

    public var errorDescription: String? {
        "ストリーミングサーバーがエラーを返しました（\(status.map(String.init) ?? "-")）: \(message)"
    }
}

/// WebSocketで届いたテキストを読む。
public enum StreamingMessageDecoder {
    private struct Envelope: Decodable {
        let stream: [String]?
        let event: String?
        /// `update`などではJSONを文字列にしたもの、`delete`ではIDそのもの。`filters_changed`では無い。
        let payload: String?
        let error: String?
        let status: Int?
    }

    /// エラーの通知なら`StreamingServerError`を投げる。
    public static func decode(_ text: String) throws -> StreamingMessage {
        let decoder = MastodonDecoder.make()
        let envelope = try decoder.decode(Envelope.self, from: Data(text.utf8))
        if let error = envelope.error {
            throw StreamingServerError(message: error, status: envelope.status)
        }
        guard let event = envelope.event else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "eventがありません: \(text)"))
        }
        // 1本の接続で複数を購読するため、どの購読のイベントかが分からなければ配れない。
        guard let stream = envelope.stream else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(event)のstreamがありません"))
        }
        return StreamingMessage(stream: stream, event: try decodeEvent(event, envelope, decoder))
    }

    private static func decodeEvent(_ event: String, _ envelope: Envelope, _ decoder: JSONDecoder) throws -> StreamingEvent {
        switch event {
        case "update":
            return .update(try decoder.decode(Status.self, from: Data(try payload(of: envelope).utf8)))
        case "status.update":
            return .statusUpdate(try decoder.decode(Status.self, from: Data(try payload(of: envelope).utf8)))
        case "delete":
            return .delete(statusID: try payload(of: envelope))
        case "notification":
            return .notification(try decoder.decode(MastodonNotification.self, from: Data(try payload(of: envelope).utf8)))
        case "filters_changed":
            return .filtersChanged
        case "notifications_merged":
            return .notificationsMerged
        case "announcement":
            return .announcement(try decoder.decode(Announcement.self, from: Data(try payload(of: envelope).utf8)))
        case "announcement.reaction":
            return .announcementReaction(try decoder.decode(AnnouncementReactionUpdate.self, from: Data(try payload(of: envelope).utf8)))
        case "announcement.delete":
            return .announcementDelete(announcementID: try payload(of: envelope))
        case "emoji_reaction":
            return .emojiReaction(try decoder.decode(EmojiReactionUpdate.self, from: Data(try payload(of: envelope).utf8)))
        default:
            return .unhandled(name: event)
        }
    }

    private static func payload(of envelope: Envelope) throws -> String {
        guard let payload = envelope.payload else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(envelope.event ?? "")のpayloadがありません"))
        }
        return payload
    }
}
