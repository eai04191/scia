import SciaCore
import UIKit

/// タイムラインの投稿の本文の自動翻訳。決まりはdocs/auto-translation.mdにある。
extension TimelineViewController {
    /// 本文を訳文で出す投稿なら、その訳文。ブーストなら元の投稿で決める。
    func translatedBody(of status: Status) -> RichText? {
        translations?.translation(for: status.displayed)
    }

    /// 訳文が届いたか、原文と訳文を切り替えた投稿を描き直す。高さが変わる分は、リンクカードが届いたときと同じく動きでつなぐ。
    func applyTranslations(_ ids: Set<Status.ID>) {
        guard isViewLoaded else { return }
        let items = displayedItemIDs.filter { status(for: $0).map { ids.contains($0.displayed.id) } ?? false }
        reconfigureWhenShown(Set(items)) { reconfigureAnimatingHeight($0, duration: tuning.value(of: TuningCatalog.translationTransitionDuration)) }
    }

    /// 訳す言語が変わった。訳文を出すかどうかが変わるので、見えている投稿を描き直し、画面の前後を訳し直す。
    func applyTranslationLanguages() {
        guard isViewLoaded else { return }
        reconfigure(Set(displayedItemIDs.filter { status(for: $0)?.displayed.language != nil }))
        requestTranslationsAroundVisibleRows()
    }

    /// 開き直したタブの投稿を訳す。頼んでいた投稿は、ほかのタブの分に置き換わっていることがある。
    func requestTranslationsAroundVisibleRows() {
        preparedBodyRange = nil
        prepareBodiesAroundVisibleRows()
    }
}
