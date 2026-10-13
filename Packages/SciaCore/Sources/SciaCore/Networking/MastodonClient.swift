import Foundation

/// ログイン済みアカウントとしてMastodon APIを呼ぶ。
public struct MastodonClient: Sendable {
    public let credential: Credential
    private let transport: any HTTPTransport

    public init(credential: Credential, transport: any HTTPTransport) {
        self.credential = credential
        self.transport = transport
    }

    /// https://docs.joinmastodon.org/methods/timelines/#home
    public func homeTimeline(maxID: String?, limit: Int) async throws -> TimelinePage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let maxID {
            query.append(URLQueryItem(name: "max_id", value: maxID))
        }
        let (statuses, response) = try await get([Status].self, path: "api/v1/timelines/home", query: query)
        // ホームの再生成中は206が返り、中身が空でも終端とは限らない。
        return TimelinePage(statuses: statuses, isRegenerating: response.statusCode == 206)
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem]) async throws -> (T, HTTPURLResponse) {
        var request = URLRequest(url: credential.instance.appending(path: path).appending(queryItems: query))
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonAPIError.from(statusCode: response.statusCode, body: data)
        }
        return (try MastodonDecoder.make().decode(type, from: data), response)
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
