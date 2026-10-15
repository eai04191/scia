/// リクエストが使う人の操作によるものか、アプリが自分で送るものか。
///
/// レート制限で止められている間は、自動の通信だけを控える。使う人の操作は、待たせずにそのまま送る。
/// task-localなので、`RequestOrigin.$current.withValue(.automatic) { ... }`の中で作ったTaskにも引き継がれる。
public enum RequestOrigin: Sendable {
    case user
    /// つなぎ直したときやポーリングの補完、近づいたときの読み込み、既読位置の保存など。
    case automatic

    @TaskLocal public static var current: RequestOrigin = .user
}
