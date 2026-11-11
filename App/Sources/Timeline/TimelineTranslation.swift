import SciaCore
import UIKit

/// タイムラインの投稿の本文の自動翻訳。決まりはdocs/auto-translation.mdにある。
extension TimelineViewController {
    /// 本文を訳文で出す投稿なら、その訳文。ブーストなら元の投稿で決める。
    func translatedBody(of status: Status) -> RichText? {
        translations?.translation(for: TranslationSource(status.displayed))
    }

    /// 囲みの本文の自動翻訳の状態。訳文も出さず、待ってもいなければnil。
    func embedTranslation(of source: TranslationSource) -> PostContentBuilder.EmbedTranslation? {
        guard let translations else { return nil }
        if let text = translations.translation(for: source) {
            return PostContentBuilder.EmbedTranslation(text: text)
        }
        return translations.isTranslating(source) ? PostContentBuilder.EmbedTranslation(text: nil) : nil
    }

    /// `status`の行で訳すもの。投稿の本文、囲みで出している引用元かXの投稿の本文の順。`status`はブーストなら元の投稿。
    func translationSources(of status: Status) -> [TranslationSource] {
        [TranslationSource(status)] + [embedTranslationSource(of: status)].compactMap(\.self)
    }

    /// `status`の行に囲みで出している、引用元かXの投稿。読み終えていないXの投稿はnil。`status`はブーストなら元の投稿。
    func embedTranslationSource(of status: Status) -> TranslationSource? {
        let shown = quoteSourceChanges.applying(to: status)
        let filterWarnings = filterWarnings
        if let display = QuoteDisplay(quoting: shown, isRevealed: quoteReveals.isRevealed(shown), verdict: { filterWarnings.verdict(for: $0) }) {
            guard case .post(let quoted) = display else { return nil }
            return TranslationSource(quoted)
        }
        guard settings.expandsXPosts, let id = XPostLink.postID(of: status), let post = xPosts?.post(id: id) else { return nil }
        return TranslationSource(post)
    }

    /// 訳文が届いたか、原文と訳文を切り替えた投稿を描き直す。文字が替わって高さが変わるのは「続きを読む」や絵文字が届いたときと同じなので、下の投稿を動かしてつなぐ。
    func applyTranslations(_ ids: Set<TranslationSource.ID>) {
        guard isViewLoaded else { return }
        let items = displayedItemIDs.filter { status(for: $0).map { translationSources(of: $0.displayed).contains { ids.contains($0.id) } } ?? false }
        reconfigureWhenShown(Set(items)) { redrawTranslations($0) }
    }

    func redrawTranslations(_ items: Set<ItemID>) {
        guard !isShowingMenu else {
            heldTranslationItems.formUnion(items)
            return
        }
        reconfigureShiftingRowsBelow(items, duration: tuning.value(of: TuningCatalog.translationTransitionDuration))
    }

    /// 訳す言語が変わった。訳文を出すかどうかが変わるので、見えている投稿を描き直し、画面の前後を訳し直す。
    func applyTranslationLanguages() {
        guard isViewLoaded else { return }
        reconfigureWhenShown(Set(displayedItemIDs.filter { status(for: $0).map { translationSources(of: $0.displayed).contains { $0.language != nil } } ?? false })) { reconfigure($0) }
        // 隠れているタブの本文は作らない。出たときに、開き直しの経路で頼む。
        guard viewIfLoaded?.window != nil else {
            preparedBodyRange = nil
            return
        }
        requestTranslationsAroundVisibleRows()
    }

    /// 開き直したタブの投稿を訳す。頼んでいた投稿は、ほかのタブの分に置き換わっていることがある。
    func requestTranslationsAroundVisibleRows() {
        preparedBodyRange = nil
        prepareBodiesAroundVisibleRows()
    }
}
