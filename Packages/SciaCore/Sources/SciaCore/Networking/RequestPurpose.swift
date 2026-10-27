/// リクエストを、使う人がそれを待っているかで分けた目的（docs/network.md）。
///
/// レート制限で止められている間は、操作のほかの通信（自動の通信）を控える。質を上げると先読みの通信は、回線でも控える。
/// task-localなので、`RequestPurpose.$current.withValue(.display) { ... }`の中で作ったTaskにも引き継がれる。
/// 質を上げると先読みの目的は、回線と設定から`NetworkUsePolicy`が作る。呼び出し側で直接作らない。
public enum RequestPurpose: Equatable, Sendable {
    /// 使う人の操作。投稿、ビューアを開く、共有と保存、引っぱって読み込み直すなど。
    case action
    /// 行を描くのに要るか、一覧を新しく保つための通信。つなぎ直し、ポーリング、補完、既読位置の保存、行に描く画像など。
    case display
    /// 安い代わりがあり、送らなくても表示が欠けない通信。一覧のサムネイルの元の画像や、動画の最初のコマ。
    /// - Parameter onExpensiveNetwork: モバイル通信などでも送るか。
    case enhancement(onExpensiveNetwork: Bool)
    /// まだ画面に出ていないものを、開いたときに待たせないために読む通信。Wi-Fiでだけ送る。
    case prefetch

    @TaskLocal public static var current: RequestPurpose = .action

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

/// 目的ごとの、送ってよい回線。
public struct NetworkAccess: Hashable, Sendable {
    /// モバイル通信や、インターネット共有のように通信量に限りのある回線。
    public let expensive: Bool
    /// 低データモード。
    public let constrained: Bool
}
