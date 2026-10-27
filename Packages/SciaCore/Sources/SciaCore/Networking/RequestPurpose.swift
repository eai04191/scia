/// リクエストを、使う人がそれを待っているかで分けた目的（docs/network.md）。
///
/// レート制限で止められている間は、操作のほかの通信（自動の通信）を控える。
/// task-localなので、`RequestPurpose.$current.withValue(.display) { ... }`の中で作ったTaskにも引き継がれる。
public enum RequestPurpose: Equatable, Sendable {
    /// 使う人の操作。投稿、ビューアを開く、共有と保存、引っぱって読み込み直すなど。
    case action
    /// 行を描くのに要るか、一覧を新しく保つための通信。つなぎ直し、ポーリング、補完、既読位置の保存、行に描く画像など。
    case display

    @TaskLocal public static var current: RequestPurpose = .action

    /// レート制限で止められている間に控える通信か。
    public var isAutomatic: Bool {
        self != .action
    }
}
