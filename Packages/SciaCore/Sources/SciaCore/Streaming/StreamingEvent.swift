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
    /// まだ扱っていない種類のイベント（お知らせなど）。
    case unhandled(name: String)
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
        let event: String?
        /// `update`などではJSONを文字列にしたもの、`delete`ではIDそのもの。`filters_changed`では無い。
        let payload: String?
        let error: String?
        let status: Int?
    }

    /// エラーの通知なら`StreamingServerError`を投げる。
    public static func decode(_ text: String) throws -> StreamingEvent {
        let decoder = MastodonDecoder.make()
        let envelope = try decoder.decode(Envelope.self, from: Data(text.utf8))
        if let error = envelope.error {
            throw StreamingServerError(message: error, status: envelope.status)
        }
        guard let event = envelope.event else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "eventがありません: \(text)"))
        }
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
