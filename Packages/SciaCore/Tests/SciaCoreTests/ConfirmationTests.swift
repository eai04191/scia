import Testing
@testable import SciaCore

@MainActor
struct ConfirmationTests {
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
        #expect(Confirmation.quoting(draft: draft(text: "本文")) == nil)
        let confirmation = Confirmation.quoting(draft: draft(poll: true))
        #expect(confirmation?.title == "投票を外して引用しますか？")
        #expect(confirmation?.buttons.last == .init("外して引用", role: .destructive, choice: .proceed))
    }

    @Test func leavingEditConfirmsOnlyWhileEditing() {
        #expect(Confirmation.leavingEdit(title: "編集をやめて返信しますか？", draft: draft(text: "本文")) == nil)
    }

    @Test func rewritingConfirmsOnlyWithWrittenDraft() {
        #expect(Confirmation.rewriting(draft: draft()) == nil)
        let confirmation = Confirmation.rewriting(draft: draft(text: "書きかけ"))
        #expect(confirmation?.title == "下書きを捨てて書き直しますか？")
        #expect(confirmation?.message == "書きかけの下書きは消えます。")
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
        #expect(text.message == "共有された文を、下書きの後ろに足すか、下書きを捨てて新しく書くかを選んでください。")
        #expect(images.message == "共有された画像を、下書きに足すか、下書きを捨てて新しく書くかを選んでください。")
        #expect(text.buttons.map(\.choice) == [.append, .discardAndWrite, .cancel])
        #expect(text.buttons.map(\.title) == ["下書きに足す", "下書きを捨てて新しく書く", "キャンセル"])
    }
}
