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

    /// ストリーミングAPIの接続先。REST APIと別のホストのことがある。
    /// https://docs.joinmastodon.org/methods/instance/#v2
    public func streamingURL() async throws -> URL {
        struct Instance: Decodable {
            struct Configuration: Decodable {
                struct URLs: Decodable {
                    let streaming: URL
                }
                let urls: URLs
            }
            let configuration: Configuration
        }
        return try await get(Instance.self, path: "api/v2/instance", query: []).0.configuration.urls.streaming
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem]) async throws -> (T, HTTPURLResponse) {
        let url = credential.instance.appending(path: path)
        var request = URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query))
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonAPIError.from(statusCode: response.statusCode, body: data)
        }
        return (try MastodonDecoder.make().decode(type, from: data), response)
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
    /// トークンが無効で、ログインし直す必要がある。
    public var isUnauthorized: Bool { statusCode == 401 }
}
