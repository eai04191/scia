public import Foundation
import os

/// アプリの通信の入口。REST API、ログイン、画像、ファイル、fxtwitter、リンク先のページが通り、同じ決まりに従う（docs/network.md）。
///
/// - 自動の通信（`RequestOrigin.automatic`）は、止められている間は送らずに`AutomaticRequestsPaused`を投げる
/// - 429や503が再開の時刻を示したら、その単位（`Scope`）の自動の通信を時刻まで止める
/// - GETと`Idempotency-Key`付きは、一時的な失敗（502、504、再開の時刻のない503、通信の失敗）で、その場で送り直す
/// - 応答は、用途ごとに決めた大きさ（`ResponseLimit`）までしか読まない
///
/// ストリーミングの接続は`StreamingClient`が、同じ門と分け方で開く。
public struct HTTPClient: Sendable {
    /// 429や503で、自動の通信を止める単位。
    public enum Scope: Sendable {
        /// ログインしたアカウントのAPI。Mastodonは制限をアカウントごとに数えるため、セッションの門で止める。
        case account(RateLimitGate)
        /// APIの外のURL（画像、ファイル、fxtwitter、リンク先のページ）。サーバーが再開の時刻を示したら、そのホストを止める。
        /// `/media_proxy`は止めない。画像のストアが、ストアごとにまとめて止める（docs/image-loading.md）。
        case host
    }

    private let transport: any HTTPTransport
    private let hosts: HostRateLimits
    private let retry: RetryPolicy
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private static let logger = SciaLog.logger(category: "network")

    /// - Parameters:
    ///   - hosts: ホストごとに止める門。アプリで1つを共有する。
    ///   - clock: 送り直すまで待つ。テストでは手で進める時計を渡す。
    ///   - now: 応答の`X-RateLimit-Reset`のような再開の時刻を、待つ長さに直すための今の日付。
    public init(
        transport: any HTTPTransport,
        hosts: HostRateLimits = HostRateLimits(),
        retry: RetryPolicy = .standard,
        clock: any Clock<Duration> = SystemTime.clock,
        now: @escaping @Sendable () -> Date = SystemTime.now
    ) {
        self.transport = transport
        self.hosts = hosts
        self.retry = retry
        self.clock = clock
        self.now = now
    }

    /// 本文を`limit`バイトまで読み、ステータスを問わず返す。2xx以外の本文を読む呼び出し（REST APIのエラーの理由など）が使う。
    /// - Parameters:
    ///   - retries: falseなら、GETでも送り直さない。
    ///   - beforeAttempt: 送るたび（送り直しを含む）の前に呼ぶ。投げたら送らない。
    public func response(
        for request: URLRequest,
        limit: Int,
        scope: Scope,
        retries allowsRetry: Bool = true,
        beforeAttempt: @Sendable () async throws -> Void = {}
    ) async throws -> (Data, HTTPURLResponse) {
        let gate = await gate(for: scope, url: request.url)
        let canRetry = allowsRetry && RetryPolicy.canRetry(request)
        var retries = 0
        while true {
            // 送り直しを待っている間に、並行する別の呼び出しが止めていることがある。
            try await beforeAttempt()
            try await checkBeforeSending(gate)
            let reason: String
            // 再開の時刻を示した429や503は、止める門がなくても（`/media_proxy`）、本文が途中で切れても、その場では送り直さない。
            var toldToWait = false
            do {
                let (body, response) = try await transport.open(request, limit: limit)
                // 本文が読めなくても止めるよう、本文を読む前に門へ反映する。
                await pause(scope, request: request, respondingTo: response)
                toldToWait = hasResumeTime(response)
                let data = try await collect(body, of: response, limit: limit)
                guard canRetry, !toldToWait, RetryPolicy.isTemporary(statusCode: response.statusCode), retries < retry.maxRetries else {
                    return (data, response)
                }
                reason = "HTTP \(response.statusCode)"
            } catch let error as URLError {
                guard canRetry, !toldToWait, RetryPolicy.isTemporary(error), retries < retry.maxRetries else { throw error }
                reason = "URLError \(error.code.rawValue)"
            }
            retries += 1
            // パスはIDを含むため残さない。
            Self.logger.info("request retry \(retries, privacy: .public) method=\(request.httpMethod ?? "GET", privacy: .public) reason=\(reason, privacy: .public)")
            try await clock.sleep(for: retry.delay(beforeRetry: retries))
        }
    }

    /// 2xxのときだけ、`limit`バイトまで読んだ本文を返す。2xx以外は本文を渡さずに`HTTPStatusError`を投げる。
    public func data(for request: URLRequest, limit: Int, scope: Scope) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await response(for: request, limit: limit, scope: scope)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusError(response: response, now: now())
        }
        return (data, response)
    }

    /// 応答の頭を受け取ったら返し、本文は届いた分から渡す。読むのをやめれば通信も止まる。範囲指定や、ページの頭だけを読むときに使う。
    /// 本文が`limit`バイトを超えたら、列を`ResponseTooLarge`で終える。2xx以外は`HTTPStatusError`を投げる。読む途中でやめられるよう、送り直さない。
    public func open(_ request: URLRequest, limit: Int, scope: Scope) async throws -> (HTTPResponseBody, HTTPURLResponse) {
        let gate = await gate(for: scope, url: request.url)
        try await checkBeforeSending(gate)
        let (body, response) = try await transport.open(request, limit: limit)
        guard (200..<300).contains(response.statusCode) else {
            await pause(scope, request: request, respondingTo: response)
            throw HTTPStatusError(response: response, now: now())
        }
        return (body, response)
    }

    /// 本文をファイルへ落とす。2xx以外は、落としたファイルを消して`HTTPStatusError`を投げる。大きいので送り直さない。
    public func download(
        _ request: URLRequest,
        limit: Int,
        scope: Scope,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, HTTPURLResponse) {
        let gate = await gate(for: scope, url: request.url)
        try await checkBeforeSending(gate)
        let (file, response) = try await transport.download(request, limit: limit, progress: progress)
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: file)
            await pause(scope, request: request, respondingTo: response)
            throw HTTPStatusError(response: response, now: now())
        }
        return (file, response)
    }

    /// 本文を`limit`バイトまで読む。頭の長さか、届いた量が超えたら、残りを受け取らずに`ResponseTooLarge`を投げる。
    private func collect(_ body: HTTPResponseBody, of response: HTTPURLResponse, limit: Int) async throws -> Data {
        guard response.expectedContentLength <= Int64(limit) else { throw ResponseTooLarge(limit: limit) }
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            guard data.count <= limit else { throw ResponseTooLarge(limit: limit) }
        }
        // 取り消されると、列は失敗せずに終わる。途中までの本文を、読み終えたものとして返さない。
        try Task.checkCancellation()
        return data
    }

    /// 429か503が、まだ来ていない再開の時刻を示しているか。
    private func hasResumeTime(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 429 || response.statusCode == 503 else { return false }
        return (RateLimitGate.retryAfter(of: response, now: now()) ?? .zero) > .zero
    }

    private func gate(for scope: Scope, url: URL?) async -> RateLimitGate? {
        switch scope {
        case .account(let gate):
            return gate
        case .host:
            guard let url, let host = url.host(), !RetrySchedule.isMediaProxy(url) else { return nil }
            return await hosts.gate(for: host)
        }
    }

    /// 送ってよいか確かめる。取り消された処理からは送らない。呼び出し側が取り消しを失敗として飲み込んでも、次の通信が出ないようにする。
    /// 自動の通信は、止められている間は送らない。
    private func checkBeforeSending(_ gate: RateLimitGate?) async throws {
        try Task.checkCancellation()
        guard let gate, RequestOrigin.current == .automatic else { return }
        try await gate.checkAutomaticRequest()
    }

    /// 429か503が再開の時刻を示していれば、その単位を止める。
    /// ホストごとに止めるときは、リダイレクトされていれば、応答したホストを止める。
    private func pause(_ scope: Scope, request: URLRequest, respondingTo response: HTTPURLResponse) async {
        guard response.statusCode == 429 || response.statusCode == 503,
              let gate = await gate(for: scope, url: response.url ?? request.url)
        else { return }
        await gate.pause(respondingTo: response)
    }
}

/// API以外の通信を、ホストごとに止める門の置き場。アプリで1つを共有し、絵文字、アイコン、添付ファイルのストアをまたいで止める。
public actor HostRateLimits {
    private var gates: [String: RateLimitGate] = [:]
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>

    public init(now: @escaping @Sendable () -> Date = SystemTime.now, clock: any Clock<Duration> = SystemTime.clock) {
        self.now = now
        self.clock = clock
    }

    func gate(for host: String) -> RateLimitGate {
        let host = host.lowercased()
        if let gate = gates[host] {
            return gate
        }
        let gate = RateLimitGate(now: now, clock: clock)
        gates[host] = gate
        return gate
    }
}

/// 応答を読む大きさの上限。用途ごとに、ふつうの応答の大きさから余裕を見て決める。超えたら読むのをやめ、待っても直らない失敗にする。
/// 上限がないと、壊れたサーバーや悪意のあるサーバーが終わりのない本文を返したときに、メモリを使い切って落ちる。
public enum ResponseLimit {
    /// REST APIとログイン。大きいサーバーの`/api/v1/custom_emojis`がおよそ2.2MB（2026年10月のfedibird.com）で、その7倍ほどにする。
    public static let api = 16 * 1_024 * 1_024
    /// 画像（絵文字、アイコン、添付ファイル、リンクのカード）。Mastodonの添付の画像の上限は16MB（`MediaAttachment::IMAGE_LIMIT`）で、
    /// ほかの実装のサーバーの画像を直接読むこともあるため、その倍にする。
    public static let image = 32 * 1_024 * 1_024
    /// fxtwitterの投稿。4枚の画像の付いた投稿でも数十KB。
    public static let xPost = 2 * 1_024 * 1_024
    /// 共有と保存で落とすファイル。Mastodonの動画の上限は99MB（`MediaAttachment::VIDEO_LIMIT`）。ほかの実装の長い動画も落とせるよう大きく取り、
    /// 端末の空きを食いつぶさない範囲で止める。
    public static let download = 1_024 * 1_024 * 1_024
    /// リンク先のページから、タイトルを探して読む量。YouTubeの動画のページは全体で700KBほどで、og:titleは500KBを過ぎたあたりにある。
    /// ほかと違い、超えたら失敗にせず、そこまでで探す。
    public static let pageTitle = 2_000_000
}
