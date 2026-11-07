/// 投稿欄で書く、ログインしているほかのアカウントと、そのアカウントのサーバーへ送る口。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
/// 送り先だけでなく、添付のアップロードと代替テキストもそのサーバーへ送る。添付はアップロードしたサーバーでしか使えないため。
public struct ComposeAccount<Thumbnail> {
    /// ログインしているアカウントを見分けるもの（`Credential.id`）。
    public let id: String
    /// そのサーバーでの自分のアカウントのID。返信の宛先から自分を除くのに使う。
    public let myAccountID: String
    /// 下書きをそのアカウントのサーバーへ送る。ふつうはそのアカウントの`MastodonClient.submit(_:)`を渡す。
    public let submit: (StatusDraft) async throws -> SubmittedDraft
    /// そのアカウントで送れたとき、下書きを空に戻す前に呼ぶ。今のアカウントの一覧には反映しない。IDがサーバーごとに違うため。
    /// 今のアカウントの`ComposeModel.onSubmitted`は、ほかのアカウントで送ったときは呼ばない。
    public let onSubmitted: (SubmittedDraft) -> Void
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
        onSubmitted: @escaping (SubmittedDraft) -> Void = { _ in },
        submit: @escaping (StatusDraft) async throws -> SubmittedDraft
    ) {
        self.id = id
        self.myAccountID = myAccountID
        self.media = media
        self.redraft = redraft
        self.onRedraftDeleted = onRedraftDeleted
        self.onSubmitted = onSubmitted
        self.submit = submit
    }
}
