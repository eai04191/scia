/// 今のアカウントで、自分の投稿を引用できる人を変え、自分の投稿への引用を取り消す。決まりはdocs/quote.mdの「投稿したあとに変える」と「引用を取り消す」にある。
/// サーバーが受け付けたら、セッションが持つどの一覧にも結果を当てる（`SessionStatuses.updateStatus(_:_:)`）。
/// 取り消しは元に戻せないので、呼ぶ前に`Confirmation.revokingQuote`で確かめる。
@MainActor
public final class QuoteControl {
    private let client: MastodonClient
    private let statuses: SessionStatuses
    private let tasks: TaskScope

    /// - Parameter tasks: 送る処理の持ち主。セッションの持ち主の子を渡す。
    public convenience init(session: AccountSession, tasks: TaskScope) {
        self.init(client: session.client, statuses: session.statuses, tasks: tasks)
    }

    init(client: MastodonClient, statuses: SessionStatuses, tasks: TaskScope) {
        self.client = client
        self.statuses = statuses
        self.tasks = tasks
    }

    /// 引用できる人を変える。ブーストを渡せば、ブーストされた投稿を変える。
    /// - Parameter onFinish: 変えられたらnil、変えられなければ理由を渡して呼ぶ。
    public func setPolicy(_ policy: QuotePolicy, of status: Status, onFinish: @escaping @MainActor ((any Error)?) async -> Void) {
        let id = status.displayed.id
        tasks.run(key: "quotePolicy:\(id)", .skippingWhileRunning, .action) { [client, statuses] in
            do {
                let updated = try await client.setQuotePolicy(policy, of: id)
                statuses.updateStatus(id) { $0.adoptingQuoteApproval(of: updated) }
                await onFinish(nil)
            } catch {
                await onFinish(error)
            }
        }
    }

    /// `quoting`の投稿による、自分の投稿への引用を取り消す。ブーストを渡せば、ブーストされた投稿の引用を取り消す。
    /// 取り消せたら、その投稿の引用を取り消した状態にし、引用元の引用の数を1つ減らす。
    /// - Parameter onFinish: 取り消せたらnil、取り消せなければ理由を渡して呼ぶ。引用元が分からない投稿では呼ばない。
    public func revoke(_ quoting: Status, onFinish: @escaping @MainActor ((any Error)?) async -> Void) {
        let shown = quoting.displayed
        guard let quotedID = shown.quote?.quotedStatusID else { return }
        tasks.run(key: "revokeQuote:\(shown.id)", .skippingWhileRunning, .action) { [client, statuses] in
            do {
                let revoked = try await client.revokeQuote(of: quotedID, by: shown.id)
                // 応答に引用がなければ、取り消した状態を手元で作る。行を取り消す前のまま残さないため。
                let quote = revoked.quote ?? Quote(state: Quote.State.revoked.rawValue)
                statuses.updateStatus(shown.id) { $0.replacingQuote(quote) }
                statuses.quoteWasRevoked(by: shown.id)
                statuses.updateStatus(quotedID) { $0.adjustingQuotesCount(by: -1) }
                await onFinish(nil)
            } catch {
                await onFinish(error)
            }
        }
    }
}
