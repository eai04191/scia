import Foundation
import os

/// fxtwitterのAPIからXの投稿を読む。
public struct XPostClient: Sendable {
    static let baseURL = URL(string: "https://api.fxtwitter.com")

    /// 投稿がないか、読めない。
    public struct Unavailable: Error, Equatable {
        public let statusCode: Int
    }

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func post(id: String) async throws -> XPost {
        guard let url = Self.baseURL?.appending(components: "status", id) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw Unavailable(statusCode: response.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = try decoder.decode(FxTwitterResponse.self, from: data)
        guard body.code == 200, let tweet = body.tweet else { throw Unavailable(statusCode: body.code) }
        return XPost(tweet)
    }
}

/// 読んだXの投稿を、セッションの中で覚える。同じ投稿を並べた一覧とタブで、1回だけ読む。
///
/// 失敗した投稿は、このセッションでは読み直さない。サーバーのカードを出したままにする。
@MainActor
public final class XPostStore {
    public typealias Fetch = @Sendable (String) async throws -> XPost

    private enum Entry {
        case loading
        case loaded(XPost)
        case failed
    }

    private let fetch: Fetch
    private var entries: [String: Entry] = [:]
    /// 読み終えた投稿のIDを渡す。その投稿へのリンクを出している行を描き直す。
    public var onLoad: ((String) -> Void)?
    private let logger = SciaLog.logger(category: "xpost")

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public convenience init(client: XPostClient) {
        self.init(fetch: { try await client.post(id: $0) })
    }

    /// 読み終えていれば、その投稿。
    public func post(id: String) -> XPost? {
        if case .loaded(let post)? = entries[id] { post } else { nil }
    }

    /// まだ読んでいなければ読みに行く。読み終えたら`onLoad`で知らせる。
    public func request(id: String) {
        guard entries[id] == nil else { return }
        entries[id] = .loading
        let fetch = fetch
        Task { [weak self] in
            do {
                let post = try await fetch(id)
                self?.finish(id, with: .loaded(post))
            } catch {
                self?.logger.error("x post fetch failed: \(SciaLog.describe(error), privacy: .public)")
                self?.finish(id, with: .failed)
            }
        }
    }

    private func finish(_ id: String, with entry: Entry) {
        entries[id] = entry
        if case .loaded = entry {
            onLoad?(id)
        }
    }
}
