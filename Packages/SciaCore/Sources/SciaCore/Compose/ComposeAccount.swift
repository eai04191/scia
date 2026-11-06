/// 投稿欄で書く、ログインしているほかのアカウントと、そのアカウントのサーバーへ送る口。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
/// 送り先だけでなく、添付のアップロードと代替テキストもそのサーバーへ送る。添付はアップロードしたサーバーでしか使えないため。
public struct ComposeAccount<Thumbnail> {
    /// ログインしているアカウントを見分けるもの（`Credential.id`）。
    public let id: String
    /// そのサーバーでの自分のアカウントのID。返信の宛先から自分を除くのに使う。
    public let myAccountID: String
    /// 新しい投稿、予約、編集を送る。編集なら`StatusDraft.editing`がある。
    public let post: (StatusDraft) async throws -> Void
    public let media: ComposeMediaService<Thumbnail>
    /// そのアカウントの投稿を削除して書き直すときに、元の投稿を消して添付が外れるのを待つ口。
    public let redraft: ComposeRedraftService
    /// 削除して書き直す元の投稿を消せたときに、そのサーバーでのIDを渡して呼ぶ。今のアカウントのタイムラインからは除かない。IDがサーバーごとに違うため。
    public let onRedraftDeleted: (Status.ID) -> Void

    public init(
        id: String,
        myAccountID: String,
        media: ComposeMediaService<Thumbnail>,
        redraft: ComposeRedraftService = .unavailable,
        onRedraftDeleted: @escaping (Status.ID) -> Void = { _ in },
        post: @escaping (StatusDraft) async throws -> Void
    ) {
        self.id = id
        self.myAccountID = myAccountID
        self.media = media
        self.redraft = redraft
        self.onRedraftDeleted = onRedraftDeleted
        self.post = post
    }
}
