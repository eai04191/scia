/// ユーザーがアカウントの設定で決めた、クライアントをまたいで使う設定のうち、Sciaが使うもの。
/// https://docs.joinmastodon.org/methods/preferences/
public struct ServerPreferences: Sendable, Equatable {
    /// 新しく投稿するときの公開範囲の既定値。
    public var defaultVisibility: Status.Visibility
    /// 注意書き（CW）のある投稿を、最初から開いておくか。
    public var expandsSpoilers: Bool

    public init(defaultVisibility: Status.Visibility, expandsSpoilers: Bool) {
        self.defaultVisibility = defaultVisibility
        self.expandsSpoilers = expandsSpoilers
    }
}
