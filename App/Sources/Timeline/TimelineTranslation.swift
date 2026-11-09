import SciaCore
import UIKit

/// タイムラインの投稿の本文の自動翻訳。決まりはdocs/auto-translation.mdにある。
extension TimelineViewController {
    /// 本文を訳文で出す投稿なら、その訳文。ブーストなら元の投稿で決める。
    func translatedBody(of status: Status) -> RichText? {
        translations?.translation(for: status.displayed)
    }

    /// 訳文が届いたか、原文と訳文を切り替えた投稿を描き直す。文字が替わって高さが変わるのは「続きを読む」や絵文字が届いたときと同じなので、下の投稿を動かしてつなぐ。
    func applyTranslations(_ ids: Set<Status.ID>) {
        guard isViewLoaded else { return }
        let items = displayedItemIDs.filter { status(for: $0).map { ids.contains($0.displayed.id) } ?? false }
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
        reconfigureWhenShown(Set(displayedItemIDs.filter { status(for: $0)?.displayed.language != nil })) { reconfigure($0) }
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
