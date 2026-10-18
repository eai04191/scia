/// 投稿の中の引用。引用された投稿の中身は、引用の表示を作るときに足す。
/// https://docs.joinmastodon.org/entities/Quote/
public struct Quote: Codable, Hashable, Sendable {
    /// 引用された人が認めたか（`accepted`、`pending`など）。
    public let state: String

    public init(state: String) {
        self.state = state
    }
}
