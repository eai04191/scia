public import Foundation
import os
import Synchronization

/// REST APIの失敗の記録。ログに残し、「接続の状態」画面に出すために最近のものを保持する。セッションの中で共有する。
///
/// リリース版の記録だけで原因を絞れるよう、メソッド、IDを伏せたパス、ステータス、失敗の種類を残す。
/// 読めなかった応答では、どの項目にどんな形の値があったかを残し、値そのものは残さない。
/// 応答の本文は個人情報を含みうるため、`includesBody`のとき（デバッグ版）だけ足す。組み立てる処理はどちらも同じ。
public final class RequestLog: Sendable {
    private let state = Mutex<(failures: [RequestFailure], nextID: Int, deprecated: [DeprecatedEndpoint])>(([], 0, []))
    private let includesBody: Bool
    private let capacity: Int
    private let now: @Sendable () -> Date
    private let logger = SciaLog.logger(category: "network")

    /// - Parameter now: 失敗した日時として残す今の日付。
    public init(includesBody: Bool, capacity: Int = 50, now: @escaping @Sendable () -> Date = SystemTime.now) {
        self.includesBody = includesBody
        self.now = now
        self.capacity = capacity
    }

    /// 新しい順。
    public var recentFailures: [RequestFailure] {
        state.withLock { $0.failures }
    }

    /// 失敗を記録する。取り消しは失敗ではないので残さない。
    func record(_ request: URLRequest, statusCode: Int?, error: any Error, body: Data?) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        let kind: RequestFailure.Kind = switch error {
        case is MastodonAPIError: .status
        case let error as URLError: .network(code: error.code.rawValue)
        case let error as DecodingError: .decoding(DecodingLog.describe(error, in: body))
        default: .other(String(describing: type(of: error)))
        }
        let failure = state.withLock { state in
            defer { state.nextID += 1 }
            let failure = RequestFailure(
                id: state.nextID,
                date: now(),
                method: request.httpMethod ?? "GET",
                path: request.url.map(Self.redactedPath) ?? "",
                statusCode: statusCode,
                kind: kind,
                body: includesBody ? body.map { String(decoding: $0.prefix(2000), as: UTF8.self) } : nil
            )
            state.failures.insert(failure, at: 0)
            state.failures = Array(state.failures.prefix(capacity))
            return failure
        }
        logger.error("request failed \(failure.logMessage, privacy: .public)")
    }

    /// 見つけた順。
    var deprecatedEndpoints: [DeprecatedEndpoint] {
        state.withLock { $0.deprecated }
    }

    /// 応答が`Deprecation`ヘッダー（RFC 9745。Mastodon 4.4から）を付けていたら、非推奨のAPIとしてログに残す。同じメソッドとパスは1度だけ残す。
    /// https://docs.joinmastodon.org/api/guidelines/#deprecations
    func noteDeprecation(of request: URLRequest, in response: HTTPURLResponse) {
        guard let value = response.value(forHTTPHeaderField: "Deprecation") else { return }
        let method = request.httpMethod ?? "GET"
        let path = request.url.map(Self.redactedPath) ?? ""
        // `@`に続くUNIX時間の秒。ほかの形なら、いつからかは残さない。
        let since = value.hasPrefix("@") ? Int(value.dropFirst()) : nil
        let endpoint = DeprecatedEndpoint(method: method, path: path, since: since)
        let isNew = state.withLock { state in
            guard !state.deprecated.contains(where: { $0.method == method && $0.path == path }) else { return false }
            state.deprecated.append(endpoint)
            return true
        }
        guard isNew else { return }
        logger.warning("deprecated API \(endpoint.logMessage, privacy: .public)")
    }

    /// パスのうち、IDらしいところを`:id`に伏せる。クエリはIDやacctを含むため残さない。
    /// `v1`のような版を除き、数字を含む部分をIDとみなす。Mastodonの数字のIDも、ULIDなど英数字のIDも伏せられる。
    /// `tag`と`tags`の次はハッシュタグの名前なので、`:name`に伏せる。
    static func redactedPath(_ url: URL) -> String {
        let components = url.pathComponents.filter { $0 != "/" }
        return "/" + components.indices
            .map { index in
                let component = components[index]
                if index > 0, ["tag", "tags"].contains(components[index - 1]) { return ":name" }
                let isVersion = component.wholeMatch(of: /v\d+/) != nil
                return !isVersion && component.contains(where: \.isNumber) ? ":id" : component
            }
            .joined(separator: "/")
    }
}

/// サーバーが非推奨と知らせたAPI。
struct DeprecatedEndpoint: Sendable, Equatable {
    let method: String
    /// IDを伏せたパス。
    let path: String
    /// 非推奨になった、またはなる日時のUNIX時間の秒。サーバーが日時を付けなければnil。
    let since: Int?

    var logMessage: String {
        let line = "\(method) \(path)"
        return since.map { "\(line) since=@\($0)" } ?? line
    }
}

/// REST APIの失敗1件。
public struct RequestFailure: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// 2xx以外のステータスが返った。
        case status
        /// 応答が届かなかった。URLErrorのコード。
        case network(code: Int)
        /// 応答を読めなかった。どの項目にどんな形の値があったか。
        case decoding(String)
        case other(String)
    }

    public let id: Int
    public let date: Date
    public let method: String
    /// IDを伏せたパス。
    public let path: String
    /// 応答が届かなかったときはnil。
    public let statusCode: Int?
    public let kind: Kind
    /// 応答の本文。デバッグ版でだけ残す。
    public let body: String?

    /// 種類を短く表したもの。「HTTP 404」「URLError -1009」など。
    public var kindDescription: String {
        switch kind {
        case .status: "HTTP \(statusCode ?? 0)"
        case .network(let code): "URLError \(code)"
        case .decoding(let detail): "HTTP \(statusCode ?? 0) decoding \(detail)"
        case .other(let type): type
        }
    }

    /// ログに残す1行。
    public var logMessage: String {
        let line = "\(method) \(path) \(kindDescription)"
        return body.map { "\(line) body=\($0)" } ?? line
    }
}
