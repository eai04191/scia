import SciaCore
import UIKit

extension TimelineViewController {
    /// 投稿の投票。投票がなければnil。ブーストなら、元の投稿を渡す。
    /// - Parameter allowsVoting: 投票する形にしてよい。投票の終了の通知のように、結果を知るために出す場所ではfalseにする。
    func pollContent(for shown: Status, allowsVoting: Bool = true, base: UIListContentConfiguration) -> PollView.Content? {
        guard let poll = shown.poll else { return nil }
        let font = base.secondaryTextProperties.font
        // 選択肢は投稿した人が書いたものなので、本文と同じく投稿の言語で描く。
        let renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: emojiImages, language: settings.glyphLanguageIdentifier(for: shown.language))
        return PollView.Content(
            pollID: poll.id,
            display: PollDisplay(poll: poll, choices: pollChoices, now: now(), allowsVoting: allowsVoting),
            titles: poll.options.map { renderer.render(.plain($0.title, emojis: poll.emojis)) },
            titleFont: font,
            optionSpacing: tuning.value(of: TuningCatalog.pollOptionSpacing),
            optionPadding: tuning.value(of: TuningCatalog.pollOptionPadding),
            barDuration: tuning.value(of: TuningCatalog.pollBarDuration)
        )
    }

    /// 投票の選択肢やボタンが押されたときの処理。選んだ状態はこの一覧で覚え、同じ投票の行をまとめて描き直す。
    /// - Parameter anchorID: 押した行。描き直しても、この行の画面上の位置を保つ。
    func handlePollAction(_ action: PollView.Action, on status: Status, keeping anchorID: ItemID?) {
        guard let poll = status.displayed.poll else { return }
        switch action {
        case .toggle(let index):
            pollChoices.toggle(index, in: poll)
        case .submit:
            let selection = pollChoices.selection(of: poll)
            guard !selection.isEmpty, !pollChoices.isSubmitting(poll.id), let onVote else { return }
            pollChoices.beginSubmitting(poll.id)
            onVote(selection, status)
        case .reveal:
            pollChoices.reveal(poll.id)
        case .returnToVoting:
            pollChoices.returnToVoting(poll.id)
        case .refresh:
            guard !pollChoices.isRefreshing(poll.id), let onRefreshPoll else { return }
            pollChoices.beginRefreshing(poll.id)
            onRefreshPoll(status)
        }
        reconfigurePoll(poll.id, keeping: anchorID)
    }

    /// 投票を送り終えた。投票の結果は、送った側がすべての一覧の投稿に反映する。
    func finishVoting(_ pollID: Poll.ID, succeeded: Bool) {
        pollChoices.endSubmitting(pollID, succeeded: succeeded)
        reconfigurePoll(pollID)
    }

    /// 投票を読み直し終えた。読み直した結果は、読んだ側がすべての一覧の投稿に反映する。
    func finishRefreshingPoll(_ pollID: Poll.ID) {
        pollChoices.endRefreshing(pollID)
        reconfigurePoll(pollID)
    }

    private func reconfigurePoll(_ pollID: Poll.ID, keeping anchorID: ItemID? = nil) {
        guard isViewLoaded else { return }
        let ids = displayedItemIDs.filter { self.status(for: $0)?.displayed.poll?.id == pollID }
        reconfigure(Set(ids), keeping: anchorID)
    }
}
