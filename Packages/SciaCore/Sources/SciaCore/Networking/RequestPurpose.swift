import os

/// リクエストを、使う人がそれを待っているかで分けた目的（docs/network.md）。
///
/// レート制限で止められている間は、操作のほかの通信（自動の通信）を控える。質を上げると先読みの通信は、回線でも控える。
/// task-localなので、`RequestPurpose.$current.withValue(.display) { ... }`の中で作ったTaskにも引き継がれる。
/// 名乗らずに送れる既定値は持たない。セッションの持ち主（`TaskScope`）で始める処理は始めるときに名乗らせ、
/// それ以外の経路で名乗らずに送ろうとした通信は、送らずに`UndeclaredRequestPurpose`で失敗させる。
/// 質を上げると先読みの目的は、回線と設定から`NetworkUsePolicy`が作る。呼び出し側で直接作らない。
public enum RequestPurpose: Equatable, Sendable {
    /// 使う人の操作。投稿、ビューアを開く、共有と保存、引っぱって読み込み直すなど。
    case action
    /// 行を描くのに要るか、タイムラインを新しく保つための通信。つなぎ直し、ポーリング、補完、既読位置の保存、行に描く画像など。
    case display
    /// 安い代わりがあり、送らなくても表示が欠けない通信。タイムラインのサムネイルの元の画像や、動画の最初のコマ。
    /// - Parameter onExpensiveNetwork: モバイル通信などでも送るか。
    case enhancement(onExpensiveNetwork: Bool)
    /// まだ画面に出ていないものを、開いたときに待たせないために読む通信。Wi-Fiでだけ送る。
    case prefetch

    /// 今の処理が名乗った目的。名乗っていなければnil。
    @TaskLocal public static var current: RequestPurpose?

    /// 今の処理が名乗った目的。名乗っていなければ、送らずに`UndeclaredRequestPurpose`を投げる。
    /// 名乗り忘れた通信を、使う人の操作として黙って送らないため。
    static func declared() throws -> RequestPurpose {
        guard let current else {
            logger.fault("request without declared purpose")
            throw UndeclaredRequestPurpose()
        }
        return current
    }

    private static let logger = SciaLog.logger(category: "network")

    /// レート制限で止められている間に控える通信か。
    public var isAutomatic: Bool {
        self != .action
    }

    /// 送ってよい回線。読み込みを待ち合わせるときは、これが同じ処理とだけ合流する。
    /// 制限の厳しい処理にOSが断った失敗を、制限のない処理に引き継がないため。
    public var networkAccess: NetworkAccess {
        switch self {
        case .action, .display: NetworkAccess(expensive: true, constrained: true)
        case .enhancement(let onExpensiveNetwork): NetworkAccess(expensive: onExpensiveNetwork, constrained: false)
        case .prefetch: NetworkAccess(expensive: false, constrained: false)
        }
    }

    /// モバイル通信などでも送ってよいか。`URLRequest.allowsExpensiveNetworkAccess`に付ける。
    var allowsExpensiveNetworkAccess: Bool { networkAccess.expensive }
    /// 低データモードでも送ってよいか。`URLRequest.allowsConstrainedNetworkAccess`に付ける。
    var allowsConstrainedNetworkAccess: Bool { networkAccess.constrained }
}

/// 目的を名乗らずに通信を送ろうとした。作りの誤りなので、待っても直らない失敗にする（`HTTPFailure.permanent`）。
public struct UndeclaredRequestPurpose: Error, Equatable, Sendable {
    public init() {}
}

/// 目的ごとの、送ってよい回線。
public struct NetworkAccess: Hashable, Sendable {
    /// モバイル通信や、インターネット共有のように通信量に限りのある回線。
    public let expensive: Bool
    /// 低データモード。
    public let constrained: Bool
}

/// 通信を送らない処理の印。`Task(.withoutRequests) { ... }`と書き、名乗らずに始める処理と見分ける。
public enum WithoutRequests: Sendable {
    case withoutRequests
}

extension Task where Failure == Never {
    /// `operation`を、通信の目的を`purpose`と名乗って始める。持ち主（`TaskScope`）を通らずに始める処理は、裸の`Task`ではなくこれで始める（`make lint`の`task_without_request_purpose`で止める）。
    @discardableResult
    public init(_ purpose: RequestPurpose, operation: @escaping @MainActor () async -> Success) {
        self.init { @MainActor in
            await RequestPurpose.$current.withValue(purpose) {
                await operation()
            }
        }
    }

    /// 通信を送らない`operation`を始める。始めたところで名乗っていた目的も引き継がない。中で通信を送ると、名乗っていない通信として失敗する。
    @discardableResult
    public init(_: WithoutRequests, operation: @escaping @MainActor () async -> Success) {
        self.init { @MainActor in
            await RequestPurpose.$current.withValue(nil) {
                await operation()
            }
        }
    }
}

extension Task where Failure == any Error {
    /// 通信を送らない`operation`を、呼んだところで今すぐ始める（`Task.immediate`）。始めたところの目的も引き継がない。
    /// クリップボードの中身のように、待つ間に読めなくなるものを読むのに使う。
    @discardableResult
    public static func immediate(_: WithoutRequests, operation: @escaping @MainActor () async throws -> Success) -> Task {
        Task.immediate { @MainActor in
            try await RequestPurpose.$current.withValue(nil) {
                try await operation()
            }
        }
    }
}
