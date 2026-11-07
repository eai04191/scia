/// 下書きを送った結果。どのAPIで送ったか（すぐ投稿、予約、編集）と、サーバーが返したもの。
/// 送るのは`MastodonClient.submit(_:)`で、送れたら`ComposeModel.onSubmitted`（ほかのアカウントで書いていれば`ComposeAccount.onSubmitted`）に渡る。
/// どの場合も、ストリーミングの知らせを待たずに一覧へ反映する。ストリーミングで届くまで数秒かかることがあり、切れている間は届かないため。
/// 今のアカウントで送った結果は、`SessionStatuses.reflect(_:usingTagsIn:)`に渡せば、下の配り先へ配る。
public enum SubmittedDraft: Sendable {
    /// すぐ投稿した。サーバーが返した投稿。
    /// ホームのタイムラインと、返信先を開いているスレッドに、`FeedTimelineModel.receivePosted(_:)`と`ThreadModel.receivePosted(_:)`で出す。
    case posted(Status)
    /// 予約した。サーバーが返した予約。予約投稿の一覧に`ScheduledStatusesModel.didSchedule(_:)`で足す。
    case scheduled(ScheduledStatus)
    /// 自分の投稿を編集した。サーバーが返した編集後の投稿。
    /// その投稿を持つ一覧すべて（タイムライン、通知、ブックマーク、お気に入り、プロフィール、スレッド、検索の結果など）で`updateStatus(_:_:)`に渡し、編集後の投稿に置き換える。
    case edited(Status)
}
