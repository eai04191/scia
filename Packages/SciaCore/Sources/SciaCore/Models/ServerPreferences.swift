/// ユーザーがアカウントの設定で決めた、クライアントをまたいで使う設定のうち、Sciaが使うもの。
/// https://docs.joinmastodon.org/methods/preferences/
public struct ServerPreferences: Sendable, Equatable {
    /// 新しく投稿するときの公開範囲の既定値。
    public var defaultVisibility: Status.Visibility
    /// 添付のある投稿を、既定で閲覧注意にするか。
    public var defaultSensitive: Bool
    /// 注意書き（CW）のある投稿を、最初から開いておくか。
    public var expandsSpoilers: Bool
    /// 新しく投稿するときの言語のコード。決めていなければnil。
    public var defaultLanguage: String?

    public init(defaultVisibility: Status.Visibility, defaultSensitive: Bool, expandsSpoilers: Bool, defaultLanguage: String? = nil) {
        self.defaultVisibility = defaultVisibility
        self.defaultSensitive = defaultSensitive
        self.expandsSpoilers = expandsSpoilers
        self.defaultLanguage = defaultLanguage
    }
}
