/// ブーストの公開範囲。設定で選ぶ既定と、メニューで選んでブーストするときに使う。
/// `rawValue`は設定に保存するため、一度使った値は変えない。
public enum ReblogVisibility: String, CaseIterable, Sendable {
    /// 公開範囲を送らず、サーバーに任せる。Mastodonは、アカウントの既定の投稿の公開範囲でブーストする。
    case accountDefault
    case `public`
    case unlisted
    case `private`

    /// ブーストのAPIに送る`visibility`。サーバーに任せるときはnil。
    /// フォロワーのみとダイレクトの投稿は、送っても元の投稿と同じ公開範囲でブーストされる。
    /// https://docs.joinmastodon.org/methods/statuses/#boost
    public var parameter: String? {
        switch self {
        case .accountDefault: nil
        case .public: "public"
        case .unlisted: "unlisted"
        case .private: "private"
        }
    }
}

extension ReblogVisibility {
    /// 設定の選択肢の名前。公開範囲を選ぶものは、投稿欄の公開範囲（`VisibilityOption`）と同じ名前にする。
    public var title: String {
        switch self {
        case .accountDefault: "アカウントのデフォルト"
        case .public: VisibilityOption(.public).title
        case .unlisted: VisibilityOption(.unlisted).title
        case .private: VisibilityOption(.private).title
        }
    }
}
