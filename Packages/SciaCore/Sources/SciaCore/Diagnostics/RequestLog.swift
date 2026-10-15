public import Foundation
import os
import Synchronization

/// REST APIの失敗の記録。ログに残し、「接続の状態」画面に出すために最近のものを覚える。セッションの中で共有する。
///
/// リリース版の記録だけで原因を絞れるよう、メソッド、IDを伏せたパス、ステータス、失敗の種類を残す。
/// 読めなかった応答では、どの項目にどんな形の値があったかを残し、値そのものは残さない。
/// 応答の本文は個人情報を含みうるため、`includesBody`のとき（デバッグ版）だけ足す。組み立てる処理はどちらも同じ。
public final class RequestLog: Sendable {
    private let state = Mutex<(failures: [RequestFailure], nextID: Int)>(([], 0))
    private let includesBody: Bool
    private let capacity: Int
    private let logger = SciaLog.logger(category: "network")

    public init(includesBody: Bool, capacity: Int = 50) {
        self.includesBody = includesBody
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
                date: Date(),
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

    /// パスのうち、IDらしいところを`:id`に伏せる。クエリはIDやacctを含むため残さない。
    /// `v1`のような版を除き、数字を含む部分をIDとみなす。Mastodonの数字のIDも、ULIDなど英数字のIDも伏せられる。
    static func redactedPath(_ url: URL) -> String {
        "/" + url.pathComponents
            .filter { $0 != "/" }
            .map { component in
                let isVersion = component.wholeMatch(of: /v\d+/) != nil
                return !isVersion && component.contains(where: \.isNumber) ? ":id" : component
            }
            .joined(separator: "/")
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
