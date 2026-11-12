/// 今のアカウントで、自分の投稿を削除する。消せたら、セッションが持つどの一覧からも除き（`SessionStatuses.removeStatus(_:)`）、
/// 投稿欄で編集か削除して書き直している投稿なら、それもやめる（`ComposeModel.statusWasDeleted(_:accountID:willReset:)`）。
/// 削除は元に戻せないので、呼ぶ前に`Confirmation.deleting`で確かめる。
/// ほかのアカウントの投稿の削除は`OtherAccount.delete(_:)`で、そのあとに`ComposeModel.statusWasDeleted(_:accountID:willReset:)`をそのアカウントのIDで呼ぶ。
@MainActor
public final class StatusDeletion {
    private let deleteStatus: @MainActor (Status.ID) async throws -> Void
    private let statuses: SessionStatuses
    private let tasks: TaskScope
    private let didDelete: @MainActor (Status.ID) -> Void
    /// 削除の応答を待つ間を数える。応答が届くまで投稿が残って表示が変わらないので、長引いたらチップで知らせるのに使う。
    public var slowActivity: SlowActivity?

    /// - Parameters:
    ///   - session: 削除を送るクライアントと、除く一覧。
    ///   - composer: 編集や書き直しをやめさせる投稿欄。
    ///   - tasks: 削除を送る処理の持ち主。セッションの持ち主の子を渡す。
    ///   - willResetComposer: 投稿欄を空に戻す直前に呼ぶ。開いているピッカーを閉じるなど、画面の側の片づけをする。
    public convenience init<Thumbnail>(
        session: AccountSession,
        composer: ComposeModel<Thumbnail>,
        tasks: TaskScope,
        willResetComposer: @escaping @MainActor () -> Void = {}
    ) {
        let client = session.client
        self.init(
            // web UIと同じく、添付もすぐ消す。送らないと、削除して書き直すために、サーバーが添付を1日ほど残すため。
            deleteStatus: { try await client.deleteStatus($0, deleteMedia: true) },
            statuses: session.statuses,
            tasks: tasks
        ) { [weak composer] id in
            composer?.statusWasDeleted(id, willReset: willResetComposer)
        }
    }

    init(
        deleteStatus: @escaping @MainActor (Status.ID) async throws -> Void,
        statuses: SessionStatuses,
        tasks: TaskScope,
        didDelete: @escaping @MainActor (Status.ID) -> Void
    ) {
        self.deleteStatus = deleteStatus
        self.statuses = statuses
        self.tasks = tasks
        self.didDelete = didDelete
    }

    /// 削除を送る。ブーストを渡せば、ブーストされた投稿を消す。送り終える前に確かめ直して押しても、同じ削除を重ねて送らない。
    /// - Parameter onFailure: 消せなかったときに呼ぶ。一覧にも投稿欄にも触れない。
    public func delete(_ status: Status, onFailure: @escaping @MainActor (any Error) async -> Void) {
        let id = status.displayed.id
        tasks.run(key: "delete:\(id)", .skippingWhileRunning, .action) { [weak self, deleteStatus, slowActivity] in
            do {
                if let slowActivity {
                    try await slowActivity.track { try await deleteStatus(id) }
                } else {
                    try await deleteStatus(id)
                }
            } catch {
                await onFailure(error)
                return
            }
            guard let self else { return }
            statuses.removeStatus(id)
            didDelete(id)
        }
    }
}
