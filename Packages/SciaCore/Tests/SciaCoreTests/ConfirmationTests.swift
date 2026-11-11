import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct ConfirmationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func draft(text: String = "", poll: Bool = false) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.text = text
        if poll {
            model.addPoll()
        }
        return model
    }

    /// 外す、取り消す、ブロックだけを確かめ、ほかは確かめずに送る。
    @Test func relationChangeConfirmsOnlyLossyChanges() {
        let unfollow = Confirmation.relationChange(.unfollow, acct: "bob@example.social")
        #expect(unfollow?.title == "@bob@example.socialのフォローを外しますか？")
        #expect(unfollow?.buttons == [.cancel, .init("フォローを外す", role: .destructive, choice: .proceed)])
        #expect(Confirmation.relationChange(.block, acct: "bob")?.message == "相手の投稿と通知が表示されなくなり、お互いのフォローが外れます。")
        #expect(Confirmation.relationChange(.cancelFollowRequest, acct: "bob")?.buttons.last?.title == "リクエストを取り消す")
        #expect(Confirmation.relationChange(.follow, acct: "bob") == nil)
        #expect(Confirmation.relationChange(.unblock, acct: "bob") == nil)
        #expect(Confirmation.relationChange(.endorse(true), acct: "bob") == nil)
        #expect(Confirmation.relationChange(.endorse(false), acct: "bob") == nil)
        // 紹介している相手のフォローを外すと、サーバーは紹介も消すので、そのことを添える。
        #expect(Confirmation.relationChange(.unfollow, acct: "bob", endorsed: true)?.message == "プロフィールでの紹介も外れます。")
    }

    /// プロフィールのフォローのボタンは、状態から送る変更を決め、ユーザーのメニューと同じ確認を使う。
    @Test func followButtonChangesFollowByState() {
        // UserRelationChangeは比べられないので、ケースの名前で比べる。
        #expect(FollowState.notFollowing(locked: false).toggleChange.map { String(describing: $0) } == "follow")
        #expect(FollowState.following.toggleChange.map { String(describing: $0) } == "unfollow")
        #expect(FollowState.requested.toggleChange.map { String(describing: $0) } == "cancelFollowRequest")
        #expect(FollowState.unknown.toggleChange == nil)
    }

    @Test func quotingConfirmsOnlyWhenPollOrMediaWouldBeRemoved() {
        #expect(Confirmation.starting(.quote(switchesAccount: false), draft: draft(text: "本文"), now: Self.now) == .proceed)
        let decision = Confirmation.starting(.quote(switchesAccount: false), draft: draft(poll: true), now: Self.now)
        let confirmation = decision.confirmation
        #expect(decision == confirmation.map { .confirm($0, leavesCurrentWork: false) })
        #expect(confirmation?.title == "投票を外して引用しますか？")
        #expect(confirmation?.buttons.last == .init("外して引用", role: .destructive, choice: .proceed))
    }

    @Test func leavingEditConfirmsOnlyWhileEditing() {
        #expect(Confirmation.starting(.reply(switchesAccount: false), draft: draft(text: "本文"), now: Self.now) == .proceed)
    }

    private func scheduled() -> ScheduledStatus {
        ScheduledStatus(id: "70", scheduledAt: Date(timeIntervalSince1970: 1_800_100_000), params: ScheduledStatus.Params(text: "予約した本文", visibility: .unlisted))
    }

    /// 予約の書き直し中の返信と引用は、返信先や引用元を付け替えて書き直しを続けるので、確かめずに進める。
    /// 投稿するアカウントを替えて始めるときは、書き直しを続けられないので、やめてよいか確かめる。押しても何も起きないままにしない。
    @Test func startingWhileRewritingScheduleAsksOnlyWhenSwitchingAccount() {
        let model = draft()
        model.beginRewriting(scheduled())

        #expect(Confirmation.starting(.reply(switchesAccount: false), draft: model, now: Self.now) == .proceed)
        #expect(Confirmation.starting(.quote(switchesAccount: false), draft: model, now: Self.now) == .proceed)

        let reply = Confirmation.starting(.reply(switchesAccount: true), draft: model, now: Self.now)
        #expect(reply == reply.confirmation.map { .confirm($0, leavesCurrentWork: true) })
        #expect(reply.confirmation?.title == "予約の書き直しをやめて返信しますか？")
        #expect(reply.confirmation?.message == "書き直し中の内容は破棄されます。元の予約は残ります。")
        #expect(reply.confirmation?.buttons == [.cancel, .init("書き直しをやめる", role: .destructive, choice: .proceed)])
        #expect(Confirmation.starting(.quote(switchesAccount: true), draft: model, now: Self.now).confirmation?.title == "予約の書き直しをやめて引用しますか？")
        #expect(Confirmation.starting(.mention, draft: model, now: Self.now).confirmation?.title == "予約の書き直しをやめてメンションしますか？")
    }

    /// 投稿を送っている間は、どの操作も始めず、待ってもらう。待てば済むので、アラートではなくチップで伝える。
    @Test(arguments: [ComposeStart.reply(switchesAccount: false), .quote(switchesAccount: true), .mention, .rewrite])
    func startingWhilePostingWaits(start: ComposeStart) async throws {
        let gate = Gate()
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in try await gate.wait() }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        model.text = "本文"
        let submitting = Task { await model.submit() }
        try await waitUntil { model.isPosting }

        #expect(Confirmation.starting(start, draft: model, now: Self.now) == .waitUntilPosted)
        #expect(Notice.startWhilePosting.title == "投稿が完了するまでお待ちください")
        gate.open()
        await submitting.value
    }

    @Test func rewritingConfirmsOnlyWithWrittenDraft() {
        #expect(Confirmation.starting(.rewrite, draft: draft(), now: Self.now) == .proceed)
        let confirmation = Confirmation.starting(.rewrite, draft: draft(text: "書きかけ"), now: Self.now).confirmation
        #expect(confirmation?.title == "下書きを破棄して書き直しますか？")
        #expect(confirmation?.message == "書きかけの下書きは破棄されます。")
    }

    /// ＋の「下書きを捨てる」は、書いたものがあるときだけ確かめ、予約の書き直しの途中ならそれをやめることを聞く。
    @Test func discardingDraftConfirmsOnlyWithWrittenDraft() {
        #expect(Confirmation.discardingDraft(draft: draft(poll: true)) == nil)
        let confirmation = Confirmation.discardingDraft(draft: draft(text: "書きかけ"))
        #expect(confirmation?.title == "下書きを破棄しますか？")
        #expect(confirmation?.message == "書きかけの下書きは破棄されます。")
        #expect(confirmation?.buttons == [.cancel, .init("破棄", role: .destructive, choice: .proceed)])

        let rewriting = draft()
        rewriting.beginRewriting(ScheduledStatus(
            id: "70", scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
            params: ScheduledStatus.Params(text: "予約した本文", visibility: .unlisted)
        ))
        #expect(Confirmation.discardingDraft(draft: rewriting)?.title == "予約の書き直しをやめますか？")
        #expect(Confirmation.discardingDraft(draft: rewriting)?.message == "書き直し中の内容は破棄されます。元の予約は残ります。")
    }

    /// 引用付きの予約投稿を書き直している間は、引用の投稿を読み直していないので`quoteTarget`がない。それでも引用を理由に断る。
    @Test func unattachableRefusalExplainsQuoteWhileRewritingScheduledQuote() {
        let model = draft()
        model.beginRewriting(ScheduledStatus(
            id: "70", scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
            params: ScheduledStatus.Params(text: "予約した引用", visibility: .unlisted, quotedStatusID: "9")
        ))
        #expect(model.quoteTarget == nil)
        #expect(RefusalText.sharedMediaUnattachable(draft: model).message == "引用する投稿には添付できません。引用をやめてからもう一度共有してください。")
        #expect(RefusalText.droppedMediaUnattachable(draft: model).message == "引用する投稿には添付できません。引用をやめてからもう一度ドロップしてください。")
    }

    @Test func sharedContentAsksWhetherToAppendOrDiscard() {
        #expect(Confirmation.shared(.text, draft: draft()) == .proceed)
        guard case .confirm(let text) = Confirmation.shared(.text, draft: draft(text: "書きかけ")),
              case .confirm(let images) = Confirmation.shared(.media(allImages: true), draft: draft(text: "書きかけ"))
        else {
            Issue.record("確かめない")
            return
        }
        #expect(text.title == "書きかけの下書きがあります")
        #expect(text.message == "共有された文を下書きの後ろに追加するか、下書きを破棄して新しく書くかを選んでください。")
        #expect(images.message == "共有された画像を下書きに追加するか、下書きを破棄して新しく書くかを選んでください。")
        #expect(text.buttons.map(\.choice) == [.append, .discardAndWrite, .cancel])
        #expect(text.buttons.map(\.title) == ["下書きに追加", "下書きを破棄して新しく書く", "キャンセル"])
    }
}
