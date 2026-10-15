public import Foundation

/// ログイン済みアカウントとしてMastodon APIを呼ぶ。
public struct MastodonClient: Sendable {
    public let credential: Credential
    private let transport: any HTTPTransport

    public init(credential: Credential, transport: any HTTPTransport) {
        self.credential = credential
        self.transport = transport
    }

    /// https://docs.joinmastodon.org/methods/timelines/#home
    public func homeTimeline(_ query: TimelineQuery) async throws -> TimelinePage {
        let (statuses, response) = try await get([Status].self, path: "api/v1/timelines/home", query: query.queryItems)
        // ホームの再生成中は206が返り、中身が空でも終端とは限らない。
        return TimelinePage(statuses: statuses, isRegenerating: response.statusCode == 206)
    }

    /// 通知を新しい順に返す。1回に読める件数の上限は80件。
    /// https://docs.joinmastodon.org/methods/notifications/#get
    public func notifications(_ query: TimelineQuery) async throws -> [MastodonNotification] {
        try await get([MastodonNotification].self, path: "api/v1/notifications", query: query.queryItems).0
    }

    /// 既読位置。まだ保存されていなければnil。
    /// https://docs.joinmastodon.org/methods/markers/#get
    public func marker(for timeline: MarkerTimeline) async throws -> String? {
        let (markers, _) = try await get([String: Marker].self, path: "api/v1/markers", query: [URLQueryItem(name: "timeline[]", value: timeline.rawValue)])
        return markers[timeline.rawValue]?.lastReadId
    }

    /// 既読位置を保存する。他の端末と同時に保存して競合すると409が返る。
    /// https://docs.joinmastodon.org/methods/markers/#create
    public func saveMarker(for timeline: MarkerTimeline, lastReadID: String) async throws {
        _ = try await post([String: Marker].self, path: "api/v1/markers", form: [URLQueryItem(name: "\(timeline.rawValue)[last_read_id]", value: lastReadID)])
    }

    /// ストリーミングAPIの接続先。REST APIと別のホストのことがある。
    public func streamingURL() async throws -> URL {
        try await instanceConfiguration().streamingURL
    }

    /// https://docs.joinmastodon.org/methods/instance/#v2
    public func instanceConfiguration() async throws -> InstanceConfiguration {
        struct Instance: Decodable {
            struct Configuration: Decodable {
                struct URLs: Decodable {
                    let streaming: URL
                }
                struct Statuses: Decodable {
                    let maxCharacters: Int?
                    let charactersReservedPerUrl: Int?
                }
                let urls: URLs
                let statuses: Statuses?
            }
            let configuration: Configuration
        }
        let configuration = try await get(Instance.self, path: "api/v2/instance", query: []).0.configuration
        // 投稿の設定を返さないサーバーには、Mastodonの既定値を使う。
        return InstanceConfiguration(
            streamingURL: configuration.urls.streaming,
            maxCharacters: configuration.statuses?.maxCharacters ?? 500,
            charactersReservedPerURL: configuration.statuses?.charactersReservedPerUrl ?? 23
        )
    }

    /// 新しく投稿するときの公開範囲の既定値。ユーザーがアカウントの設定で決めたもの。
    /// https://docs.joinmastodon.org/methods/preferences/#get
    public func defaultVisibility() async throws -> Status.Visibility {
        struct Preferences: Decodable {
            let visibility: Status.Visibility?

            private enum CodingKeys: String, CodingKey {
                case visibility = "posting:default:visibility"
            }
        }
        // キーにコロンを含むため、スネークケースからの変換を通さずに読む。
        let (data, _) = try await send(URLRequest(url: credential.instance.appending(path: "api/v1/preferences")))
        return try JSONDecoder().decode(Preferences.self, from: data).visibility ?? .public
    }

    // MARK: - 投稿への操作

    /// お気に入りに登録し、登録後の投稿を返す。
    /// https://docs.joinmastodon.org/methods/statuses/#favourite
    public func favourite(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/favourite", form: []).0
    }

    /// https://docs.joinmastodon.org/methods/statuses/#unfavourite
    public func unfavourite(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/unfavourite", form: []).0
    }

    /// ブーストし、ブーストした元の投稿を返す。APIはブーストそのものを返すため、中の元の投稿を取り出す。
    /// https://docs.joinmastodon.org/methods/statuses/#boost
    public func reblog(_ statusID: String) async throws -> Status {
        let boost = try await post(Status.self, path: "api/v1/statuses/\(statusID)/reblog", form: []).0
        return boost.reblog ?? boost
    }

    /// ブーストを取り消し、元の投稿を返す。
    /// https://docs.joinmastodon.org/methods/statuses/#unreblog
    public func unreblog(_ statusID: String) async throws -> Status {
        let status = try await post(Status.self, path: "api/v1/statuses/\(statusID)/unreblog", form: []).0
        return status.reblog ?? status
    }

    /// 投稿する。同じ下書きを送り直しても二重に投稿されないよう、下書きごとの`Idempotency-Key`を付ける。
    /// https://docs.joinmastodon.org/methods/statuses/#create
    public func postStatus(_ draft: StatusDraft) async throws -> Status {
        var form = [
            URLQueryItem(name: "status", value: draft.text),
            URLQueryItem(name: "visibility", value: draft.visibility.rawValue),
        ]
        if !draft.spoilerText.isEmpty {
            form.append(URLQueryItem(name: "spoiler_text", value: draft.spoilerText))
        }
        if let inReplyToID = draft.inReplyToID {
            form.append(URLQueryItem(name: "in_reply_to_id", value: inReplyToID))
        }
        return try await post(Status.self, path: "api/v1/statuses", form: form, headers: ["Idempotency-Key": draft.idempotencyKey]).0
    }

    /// トークンが有効なら返り、無効なら401の`MastodonAPIError`を投げる。
    /// アカウントの他の項目が読めないサーバーでも確かめられるよう、IDだけを読む。
    /// https://docs.joinmastodon.org/methods/accounts/#verify_credentials
    public func verifyCredentials() async throws {
        struct Verified: Decodable {
            let id: String
        }
        _ = try await get(Verified.self, path: "api/v1/accounts/verify_credentials", query: [])
    }

    /// https://docs.joinmastodon.org/methods/accounts/#get
    public func account(_ id: String) async throws -> Account {
        try await get(Account.self, path: "api/v1/accounts/\(id)", query: []).0
    }

    /// 自分と相手の関係。相手が見つからなければnil。
    /// https://docs.joinmastodon.org/methods/accounts/#relationships
    public func relationship(with id: String) async throws -> Relationship? {
        try await get([Relationship].self, path: "api/v1/accounts/relationships", query: [URLQueryItem(name: "id[]", value: id)]).0.first { $0.id == id }
    }

    /// アカウントの投稿を新しい順に返す。
    /// https://docs.joinmastodon.org/methods/accounts/#statuses
    public func accountStatuses(_ id: String, filter: AccountStatusFilter, query: TimelineQuery) async throws -> [Status] {
        try await get([Status].self, path: "api/v1/accounts/\(id)/statuses", query: filter.queryItems + query.queryItems).0
    }

    /// `user@domain`の形のacctからアカウントを探す。自分のサーバーが知らないアカウントも、相手のサーバーに問い合わせて探す。
    /// 見つからなければnil。
    /// https://docs.joinmastodon.org/methods/search/#v2
    public func resolveAccount(_ acct: String) async throws -> Account? {
        struct Results: Decodable {
            let accounts: [Account]
        }
        let query = [
            URLQueryItem(name: "q", value: acct),
            URLQueryItem(name: "type", value: "accounts"),
            URLQueryItem(name: "resolve", value: "true"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return try await get(Results.self, path: "api/v2/search", query: query).0.accounts.first
    }

    /// 鍵のかかったアカウントには、フォローのリクエストを送る。
    /// https://docs.joinmastodon.org/methods/accounts/#follow
    public func follow(_ id: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/follow", form: []).0
    }

    /// フォローを外す。承認を待っているリクエストも取り消す。
    /// https://docs.joinmastodon.org/methods/accounts/#unfollow
    public func unfollow(_ id: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/unfollow", form: []).0
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem]) async throws -> (T, HTTPURLResponse) {
        let url = credential.instance.appending(path: path)
        return try await send(URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query)), decoding: type)
    }

    private func post<T: Decodable>(_ type: T.Type, path: String, form: [URLQueryItem], headers: [String: String] = [:]) async throws -> (T, HTTPURLResponse) {
        var request = URLRequest(url: credential.instance.appending(path: path))
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form
        // URLComponentsは`+`をエンコードしないが、form-urlencodedでは`+`が空白として読まれるため、エンコードしておく。
        let body = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        request.httpBody = Data(body.utf8)
        return try await send(request, decoding: type)
    }

    private func send<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> (T, HTTPURLResponse) {
        let (data, response) = try await send(request)
        return (try MastodonDecoder.make().decode(type, from: data), response)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonAPIError.from(statusCode: response.statusCode, body: data)
        }
        return (data, response)
    }
}

/// インスタンスの設定のうち、Sciaが使うもの。
public struct InstanceConfiguration: Sendable, Equatable {
    public let streamingURL: URL
    /// 投稿の本文と注意書きを合わせた文字数の上限。
    public let maxCharacters: Int
    /// 本文中のURLを何文字と数えるか。
    public let charactersReservedPerURL: Int

    public init(streamingURL: URL, maxCharacters: Int, charactersReservedPerURL: Int) {
        self.streamingURL = streamingURL
        self.maxCharacters = maxCharacters
        self.charactersReservedPerURL = charactersReservedPerURL
    }
}

/// 既読位置を保存できるタイムライン。
public enum MarkerTimeline: String, Sendable {
    case home
    case notifications
}

/// https://docs.joinmastodon.org/entities/Marker/
struct Marker: Decodable {
    let lastReadId: String
}

/// アカウントの投稿の絞り込み。
public struct AccountStatusFilter: Sendable, Equatable {
    /// 他の人への返信を除く。本人への返信（自分のスレッドの続き）は、Mastodonでは除かれずに残る。
    public var excludesReplies: Bool
    public var excludesReblogs: Bool
    public var onlyMedia: Bool
    /// 固定された投稿だけを返す。
    public var pinned: Bool

    public init(excludesReplies: Bool = false, excludesReblogs: Bool = false, onlyMedia: Bool = false, pinned: Bool = false) {
        self.excludesReplies = excludesReplies
        self.excludesReblogs = excludesReblogs
        self.onlyMedia = onlyMedia
        self.pinned = pinned
    }

    var queryItems: [URLQueryItem] {
        [
            ("exclude_replies", excludesReplies),
            ("exclude_reblogs", excludesReblogs),
            ("only_media", onlyMedia),
            ("pinned", pinned),
        ].filter(\.1).map { URLQueryItem(name: $0.0, value: "true") }
    }
}

/// タイムラインのどの範囲を読むか。
/// https://docs.joinmastodon.org/api/guidelines/#pagination
public struct TimelineQuery: Sendable, Equatable {
    /// これより古い投稿を返す。
    public var maxID: String?
    /// これより新しい投稿のうち、最も新しい側から返す。
    public var sinceID: String?
    /// これより新しい投稿のうち、すぐ後に続く側から返す。
    public var minID: String?
    public var limit: Int

    public init(maxID: String? = nil, sinceID: String? = nil, minID: String? = nil, limit: Int) {
        self.maxID = maxID
        self.sinceID = sinceID
        self.minID = minID
        self.limit = limit
    }

    var queryItems: [URLQueryItem] {
        [("max_id", maxID), ("since_id", sinceID), ("min_id", minID), ("limit", String(limit))].compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
    }
}

/// タイムラインの1ページ分。
public struct TimelinePage: Sendable, Equatable {
    /// 新しい順。
    public let statuses: [Status]
    /// サーバーがホームを再生成中で、結果が揃っていない。
    public let isRegenerating: Bool

    public init(statuses: [Status], isRegenerating: Bool) {
        self.statuses = statuses
        self.isRegenerating = isRegenerating
    }
}

extension MastodonAPIError {
    /// 401。トークンが無効なことが多いが、一部のAPIだけを断るサーバーもあるため、ログインし直しが要るかは`AuthorizationCheck`で確かめる。
    public var isUnauthorized: Bool { statusCode == 401 }
}
