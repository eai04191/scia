import Foundation
import os

/// fxtwitterのAPIからXの投稿を読む。通信は`HTTPClient`を通し、2xx以外は`HTTPStatusError`で失敗させる。
/// fxtwitterが429や503で再開の時刻を示したら、ほかの投稿の自動の読み込みも、その時刻まで止める（docs/network.md）。
public struct XPostClient: Sendable {
    static let baseURL = URL(string: "https://api.fxtwitter.com")

    /// 応答の中の`code`が、投稿がないか読めないことを示した。
    public struct Unavailable: Error, Equatable {
        public let statusCode: Int
    }

    private let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    /// 投稿を読むURL。読めなかった投稿を、URLごとに読み直しの間隔で覚えるのにも使う。
    static func url(id: String) -> URL? {
        baseURL?.appending(components: "status", id)
    }

    public func post(id: String) async throws -> XPost {
        guard let url = Self.url(id: id) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await client.data(for: request, limit: ResponseLimit.xPost, scope: .host)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = try decoder.decode(FxTwitterResponse.self, from: data)
        guard body.code == 200, let tweet = body.tweet else { throw Unavailable(statusCode: body.code) }
        // 囲みを押すと開く先なので、投稿のURLと同じくhttpとhttpsだけを受け付ける。
        guard ServerURLKind.destination.accepts(tweet.url) else { throw URLError(.badServerResponse) }
        return XPost(tweet)
    }
}

/// 読んだXの投稿を、セッションの中で覚える。同じ投稿を並べた一覧とタブで、1回だけ読む。
///
/// 読めないうちは、サーバーのカードを出したままにする。待てば読める失敗（429、5xx、通信の失敗）は、画像と同じく、
/// 行を描き直したときに間隔をおいて読み直す（`RetrySchedule`）。待っても読めない失敗（投稿がないなど）は、このセッションでは読み直さない。
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
    private var retry: RetrySchedule
    /// 読み終えた投稿のIDを渡す。その投稿へのリンクを出している行を描き直す。
    public var onLoad: ((String) -> Void)?
    private let logger = SciaLog.logger(category: "xpost")

    /// - Parameters:
    ///   - clock: 読み直すまでの間隔を数える。テストでは手で進める時計を渡す。
    ///   - retryPolicy: 失敗したときに読む、読み直しの間隔。
    public init(
        clock: any Clock<Duration> = SystemTime.clock,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy,
        fetch: @escaping Fetch
    ) {
        self.fetch = fetch
        retry = RetrySchedule(policy: retryPolicy, clock: clock)
    }

    public convenience init(client: XPostClient, retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy) {
        self.init(retryPolicy: retryPolicy, fetch: { try await client.post(id: $0) })
    }

    /// 読めなかったことがあり、まだ読めていない。
    public func hasFailed(id: String) -> Bool {
        if case .failed? = entries[id] { true } else { false }
    }

    /// 読み終えていれば、その投稿。
    public func post(id: String) -> XPost? {
        if case .loaded(let post)? = entries[id] { post } else { nil }
    }

    /// まだ読んでいなければ読みに行く。前に読めなかった投稿は、読み直してよくなっていれば読み直す。読み終えたら`onLoad`で知らせる。
    /// 行に描いたときに呼ぶので、自動の通信として送り、止められている間は送らない。
    public func request(id: String) {
        switch entries[id] {
        case nil:
            break
        case .failed:
            guard let url = XPostClient.url(id: id), retry.allowsAutomaticLoad(of: url) else { return }
        case .loading, .loaded:
            return
        }
        entries[id] = .loading
        let fetch = fetch
        RequestPurpose.$current.withValue(.display) {
            Task { [weak self] in
                do {
                    let post = try await fetch(id)
                    self?.finish(id, with: .loaded(post))
                } catch {
                    self?.logger.error("x post fetch failed: \(SciaLog.describe(error), privacy: .public)")
                    self?.fail(id, with: error)
                }
            }
        }
    }

    private func fail(_ id: String, with error: any Error) {
        if let url = XPostClient.url(id: id) {
            retry.recordFailure(error, for: url)
        }
        finish(id, with: .failed)
    }

    /// 読みに行かずに、読み込み中にしておく。`deliver(_:)`で届けるまで、`request(id:)`されても読まない。
    /// ダミー投稿で、投稿が後から届くときの動きを、fxtwitterに頼まずに確かめるために使う。
    public func reserve(id: String) {
        guard entries[id] == nil else { return }
        entries[id] = .loading
    }

    /// 読まずに投稿を届ける。読み終えたときと同じく`onLoad`で知らせる。
    public func deliver(_ post: XPost) {
        finish(post.id, with: .loaded(post))
    }

    private func finish(_ id: String, with entry: Entry) {
        entries[id] = entry
        if case .loaded = entry {
            if let url = XPostClient.url(id: id) {
                retry.recordSuccess(for: url)
            }
            onLoad?(id)
        }
    }
}
