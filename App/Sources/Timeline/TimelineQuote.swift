import SciaCore
import UIKit

extension TimelineViewController {
    /// 投稿の中の引用の囲みと、その押下の処理。引用がなければnil。決まりは`docs/quote.md`。
    /// 引用元の注意書き、フィルターの警告、ぼかしは、引用元の投稿のIDで覚えている状態を当てる。
    /// - Parameter itemID: この中身を置く行。注意書きを開閉したり、ブロックした人の引用元を開いたりしたときに、この行の画面上の位置を保つ。
    func quoteEmbed(for status: Status, itemID: ItemID?, base: UIListContentConfiguration) -> (content: EmbeddedPostView.Content, actions: EmbedActions)? {
        let shown = quoteSourceChanges.applying(to: status.displayed)
        let filterWarnings = filterWarnings
        guard let display = QuoteDisplay(quoting: shown, isRevealed: quoteReveals.isRevealed(shown), verdict: { filterWarnings.verdict(for: $0) }) else { return nil }
        switch display {
        case .post(let quoted):
            let media = mediaContent(of: quoted.mediaAttachments, cover: mediaCover(for: quoted))
            let content = postContentBuilder.quote(quoted, spoiler: spoiler(of: quoted, base: base), media: media, base: base)
            var actions = EmbedActions()
            actions.open = { [weak self] view in
                guard let self else { return }
                recordOpenThread()
                let frame = view.convert(view.bounds, to: nil)
                // 引用元がさらに引用していると、その引用はIDだけで届いている。スレッドは押した投稿を読み直さないため、
                // そのまま開くと、スレッドの中で入れ子の引用を出せない。読み直してから開く。
                if quoted.quote != nil {
                    onOpenStatusID?(quoted.id, frame)
                } else {
                    onOpenThread?(quoted, frame)
                }
            }
            if let itemID {
                let open = actions.open
                actions.target = statusTarget(for: quoted, id: itemID) { view in
                    guard let embed = view as? EmbeddedPostView else { return }
                    open?(embed)
                }
                actions.accountTarget = userTarget(for: quoted.account, id: itemID)
            }
            if let media {
                actions.selectMedia = { [weak self] index, grid in
                    self?.openMedia(media.attachments, at: index, of: quoted, from: grid)
                }
            }
            actions.revealMedia = { [weak self] in self?.revealMedia(of: quoted) }
            actions.openLink = { [weak self] destination in self?.onOpenLink?(destination, quoted) }
            actions.openAccount = { [weak self] in self?.onOpenProfile?(quoted.account) }
            actions.toggleSpoiler = { [weak self] in self?.toggleSpoiler(of: quoted, keeping: itemID) }
            if case .link(let nestedID) = NestedQuote(quoted.quote) {
                actions.selectNote = { [weak self] _ in
                    guard let self else { return }
                    // 押した行の位置にスレッドの投稿を置く。行が見えなくなっていれば、画面の上端に置く。
                    let cell = itemID.flatMap { self.cell(for: $0) }
                    self.onOpenStatusID?(nestedID, cell.map { $0.convert($0.bounds, to: nil) } ?? .zero)
                }
            }
            return (content, actions)
        case .concealed(let reason, _):
            let content = postContentBuilder.quotePlaceholder(id: shown.id, message: PostContentBuilder.quoteUnavailableText(reason), revealTitle: "引用元を表示", base: base)
            var actions = EmbedActions()
            actions.open = { [weak self] _ in self?.revealQuote(of: shown, keeping: itemID) }
            return (content, actions)
        case .unavailable(let reason):
            return (postContentBuilder.quotePlaceholder(id: shown.id, message: PostContentBuilder.quoteUnavailableText(reason), revealTitle: nil, base: base), EmbedActions())
        case .filtered:
            return (postContentBuilder.quotePlaceholder(id: shown.id, message: "フィルターで隠しました", revealTitle: nil, base: base), EmbedActions())
        }
    }

    /// ブロックかミュートしている人の引用元を開く。同じ投稿をブーストした行と通知の行もまとめて描き直し、押した行の画面上の位置を保つ。
    func revealQuote(of status: Status, keeping anchorID: ItemID?) {
        quoteReveals.reveal(status)
        guard isViewLoaded else { return }
        let shownID = status.displayed.id
        let ids = displayedItemIDs.filter { self.status(for: $0)?.displayed.id == shownID }
        reconfigure(Set(ids), keeping: anchorID)
    }

    /// 引用元の、受け取ったあとの変化を受け取り、その引用元を出している行を描き直す。
    /// 使う人の操作によらない変化でも、見えている行の高さは下の行ごと動かしてつなぐ（docs/quote.md）。
    func applyQuoteSourceChanges(_ changes: QuoteSourceChanges, affecting change: QuoteSourceChange) {
        quoteSourceChanges = changes
        // まだ開いていない画面は、開いたときにこの状態で描く。描き直しのために画面を読み込ませない。
        guard isViewLoaded else { return }
        let ids = displayedItemIDs.filter { id in
            guard let quoted = self.status(for: id)?.displayed.quote?.quotedStatus else { return false }
            return switch change {
            case .status(let statusID): quoted.id == statusID || quoted.quote?.quotedStatusID == statusID
            case .account(let accountID): quoted.account.id == accountID
            }
        }
        reconfigureAnimatingHeight(Set(ids), duration: tuning.value(of: TuningCatalog.linkCardTransitionDuration))
    }
}

/// 引用元の変化の対象。
enum QuoteSourceChange {
    /// 投稿が編集されたか、削除された。
    case status(Status.ID)
    /// アカウントをミュートかブロックしたか、解除した。
    case account(String)
}
