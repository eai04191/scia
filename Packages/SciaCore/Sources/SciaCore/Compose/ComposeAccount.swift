/// 投稿欄で書く、ログインしているほかのアカウントと、そのアカウントのサーバーへ送る口。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
/// 送り先だけでなく、添付のアップロードと代替テキストもそのサーバーへ送る。添付はアップロードしたサーバーでしか使えないため。
public struct ComposeAccount<Thumbnail> {
    /// ログインしているアカウントを見分けるもの（`Credential.id`）。
    public let id: String
    /// そのサーバーでの自分のアカウントのID。返信の宛先から自分を除くのに使う。
    public let myAccountID: String
    public let post: (StatusDraft) async throws -> Void
    public let media: ComposeMediaService<Thumbnail>

    public init(id: String, myAccountID: String, media: ComposeMediaService<Thumbnail>, post: @escaping (StatusDraft) async throws -> Void) {
        self.id = id
        self.myAccountID = myAccountID
        self.media = media
        self.post = post
    }
}
