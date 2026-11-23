/// 投稿欄で書くアカウントと、そのアカウントのサーバーへ送る口。ウィンドウのアカウントも、ログインしているほかのアカウントも、この形で持つ。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
/// 送り先だけでなく、添付のアップロードと代替テキストもそのサーバーへ送る。添付はアップロードしたサーバーでしか使えないため。
public struct ComposeAccount<Thumbnail> {
    /// ログインしているアカウントを見分けるもの（`Credential.id`）。
    public let id: String
    /// そのサーバーでの自分のアカウントのID。返信の宛先から自分を除くのに使う。
    public let myAccountID: String
    /// 下書きをそのアカウントのサーバーへ送る。ふつうはそのアカウントの`MastodonClient.submit(_:quotes:)`に、そのサーバーの引用の決まりを添えて渡す。
    public let submit: (StatusDraft) async throws -> SubmittedDraft
    /// そのアカウントで送れたとき、下書きを空に戻す前に、送った結果を渡して呼ぶ。投稿、予約、編集のどれだったかと、サーバーが返したものが入る。
    /// 送り始めたときのアカウントのものを呼ぶ。送っている間にウィンドウのアカウントを替えても、替えた先の一覧に反映しないため。
    public let onSubmitted: (SubmittedDraft) -> Void
    /// 予約を書き直した投稿をそのアカウントで送れて、下書きを空に戻したあとに、元の予約のIDを渡して呼ぶ。元の予約を取り消すのは呼ぶ側。
    public let onScheduleRewritten: (ScheduledStatus.ID) -> Void
    public let media: ComposeMediaService<Thumbnail>
    /// そのアカウントの投稿を削除して書き直すときに、元の投稿を消して添付が外れるのを待つ口。
    public let redraft: ComposeRedraftService
    /// 削除して書き直す元の投稿を消せたときに、そのサーバーでのIDを渡して呼ぶ（もう消えていたときを含む）。ほかのアカウントのものは、今のアカウントのタイムラインからは除かない。IDがサーバーごとに違うため。
    public let onRedraftDeleted: (Status.ID) -> Void

    public init(
        id: String,
        myAccountID: String,
        media: ComposeMediaService<Thumbnail>,
        redraft: ComposeRedraftService = .unavailable,
        onRedraftDeleted: @escaping (Status.ID) -> Void = { _ in },
        onSubmitted: @escaping (SubmittedDraft) -> Void = { _ in },
        onScheduleRewritten: @escaping (ScheduledStatus.ID) -> Void = { _ in },
        submit: @escaping (StatusDraft) async throws -> SubmittedDraft
    ) {
        self.id = id
        self.myAccountID = myAccountID
        self.media = media
        self.redraft = redraft
        self.onRedraftDeleted = onRedraftDeleted
        self.onSubmitted = onSubmitted
        self.onScheduleRewritten = onScheduleRewritten
        self.submit = submit
    }
}
