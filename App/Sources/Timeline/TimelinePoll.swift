import SciaCore
import UIKit

extension TimelineViewController {
    /// 投稿の投票。投票がなければnil。ブーストなら、元の投稿を渡す。
    func pollContent(for shown: Status, base: UIListContentConfiguration) -> PollView.Content? {
        guard let poll = shown.poll else { return nil }
        let typography = PostTypography(settings: settings)
        let font = typography.font(.body)
        // 選択肢は投稿した人が書いたものなので、本文と同じく投稿の言語で描く。
        let renderer = RichTextRenderer(font: font, textColor: .label, settings: settings, showsCustomEmojis: appearance(for: shown).showsCustomEmojis, emojiImages: emojiImages, language: settings.glyphLanguageIdentifier(for: shown.language))
        return PollView.Content(
            pollID: poll.id,
            display: PollDisplay(poll: poll, choices: pollChoices, now: now()),
            titles: poll.options.map { renderer.render(.plain($0.title, emojis: poll.emojis)) },
            titleFont: font,
            footerFont: typography.font(.pollFooter),
            footerSpacing: settings.value(of: AppearanceCatalog.pollFooterSpacing),
            optionSpacing: settings.value(of: AppearanceCatalog.pollOptionSpacing),
            optionPadding: settings.value(of: AppearanceCatalog.pollOptionPadding),
            optionHorizontalPadding: settings.value(of: AppearanceCatalog.pollOptionHorizontalPadding),
            optionCornerRadius: settings.value(of: AppearanceCatalog.pollOptionCornerRadius),
            barDuration: tuning.value(of: TuningCatalog.pollBarDuration),
            modeChangeDuration: tuning.value(of: TuningCatalog.pollModeChangeDuration)
        )
    }

    /// 投票の選択肢やボタンが選択されたときの処理。選んだ状態はこのタイムラインで保持し、同じ投票の行をまとめて再描画する。
    /// - Parameter anchorID: 選択した行。再描画しても、この行の画面上の位置を保つ。
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

    /// 投票を送り終えた。投票の結果は、送った側がすべてのタイムラインの投稿に反映する。
    func finishVoting(_ pollID: Poll.ID, succeeded: Bool) {
        pollChoices.endSubmitting(pollID, succeeded: succeeded)
        reconfigurePoll(pollID)
    }

    /// 投票を再読み込みし終えた。再読み込みした結果は、読んだ側がすべてのタイムラインの投稿に反映する。
    func finishRefreshingPoll(_ pollID: Poll.ID) {
        pollChoices.endRefreshing(pollID)
        reconfigurePoll(pollID)
    }

    private func reconfigurePoll(_ pollID: Poll.ID, keeping anchorID: ItemID? = nil) {
        guard isViewLoaded else { return }
        let ids = displayedItemIDs.filter { self.status(for: $0)?.displayed.poll?.id == pollID }
        reconfigureShiftingRowsBelow(Set(ids), keeping: anchorID, duration: tuning.value(of: TuningCatalog.longBodyExpandDuration))
    }
}
