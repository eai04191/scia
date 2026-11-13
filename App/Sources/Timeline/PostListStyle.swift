import SciaCore
import UIKit

/// 投稿を並べるリストの見た目。投稿の中身（`PostContentBuilder`）の外で、リストが受け持つ分を持つ。
/// 区切り線の引き方と、描き直しの要る設定の変化を決める。セルは`TimelineCell`を使う。
/// 並べる画面は、投稿と違う行（返信でつながった行、検索の見出しなど）のことだけを渡す。
@MainActor
final class PostListStyle {
    let settings: AppSettings
    private let tuning: TuningStore
    private let network: NetworkConditionsMonitor

    /// 設定、チューニング、回線の状態が変わって、並べた行の描き直しが要るとき。行の中身の描き直しと、区切り線の引き直し（`invalidateLayout`）は、呼ばれた画面が行う。
    /// 溜めている間は呼ばず、溜めるのをやめたときに1回だけ呼ぶ。
    var onRedrawNeeded: () -> Void = {}
    /// リストが見えているか。見えていない間は描き直さずに溜め、見えたときに画面が`applyHeldChange`を呼んで1回だけ描き直す。
    /// 設定の+−を押すたびに、見えないリストのすべての行を組み直すと、押してから数字が変わるまでが遅れるため。
    var isShown: () -> Bool = { true }
    /// 設定の画面が手前にある間は、設定やチューニングが変わっても描き直さずに溜める。画面を閉じて外したときに、溜めた変更を1回で描き直す。
    /// 設定の画面のシートはリストをほぼ覆うので、上の端に見えているリストは、閉じるまで前の見た目のまま残る。
    var holdsChanges = false {
        didSet {
            guard !holdsChanges, oldValue else { return }
            applyHeldChange()
        }
    }
    /// 見えていない間か、`holdsChanges`の間に、設定やチューニングが変わった。
    private(set) var hasHeldChange = false

    init(settings: AppSettings, tuning: TuningStore, network: NetworkConditionsMonitor) {
        self.settings = settings
        self.tuning = tuning
        self.network = network
    }

    /// 区切り線。行と行のあいだにだけ引き、1件目の上と最後の行の下には引かない。区切り線を出さない設定では引かない。決まりはdocs/post-header-layout.mdの「区切り線」にある。
    /// - Parameters:
    ///   - leading: 線を引き始める、行の左端からの長さ。nilなら投稿の行として、本文の左端から引く。
    ///   - joinsNext: 下の行と線でつながっている行。1つの会話として見せるため、下の区切り線を出さない。
    func separator(_ base: UIListSeparatorConfiguration, isFirst: Bool, isLast: Bool, leading: CGFloat? = nil, joinsNext: Bool = false) -> UIListSeparatorConfiguration {
        var separator = base
        guard settings.appearance.showsSeparators else {
            separator.topSeparatorVisibility = .hidden
            separator.bottomSeparatorVisibility = .hidden
            return separator
        }
        if isFirst {
            separator.topSeparatorVisibility = .hidden
        }
        if isLast || joinsNext {
            separator.bottomSeparatorVisibility = .hidden
        }
        let insets = NSDirectionalEdgeInsets(top: 0, leading: leading ?? settings.postSeparatorLeading, bottom: 0, trailing: 0)
        separator.topSeparatorInsets = insets
        separator.bottomSeparatorInsets = insets
        return separator
    }

    /// 行の見た目を変える値を見張り、変わるたびに、溜めていなければ`onRedrawNeeded`を呼ぶ。
    /// サムネイルは、低データモードを抜けたときなどに、表示中のものも読む画像を選び直す。
    func observeRedrawNeeds() {
        withObservationTracking {
            _ = settings.appearanceValues
            _ = tuning.value(of: TuningCatalog.mediaThumbnailUpscaleTolerance)
            _ = settings.expandsXPosts
            _ = tuning.value(of: TuningCatalog.reactionGlowMixesInOKLab)
            _ = tuning.value(of: TuningCatalog.reactionGlowIconRiseDelay)
            _ = tuning.value(of: TuningCatalog.reactionGlowHDRExposure)
            _ = tuning.value(of: TuningCatalog.reactionGlowLightIntensity)
            _ = tuning.value(of: TuningCatalog.reactionGlowLightBloomIntensityRatio)
            _ = tuning.value(of: TuningCatalog.reactionGlowDarkGlowHDRExposure)
            _ = network.usePolicy(settings: settings)
            _ = settings.ignoresUselessAltText
            _ = settings.appearance
            _ = settings.postActionBarLayout
            // アニメーションを再生するかは、選ぶまでサーバーの値に従うため、読めた値が変わったときも描き直す。
            _ = settings.serverAutoplaysAnimations
            _ = settings.accentColor.underlinesLinks
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                guard let self else { return }
                self.observeRedrawNeeds()
                guard !self.holdsChanges, self.isShown() else {
                    self.hasHeldChange = true
                    return
                }
                self.onRedrawNeeded()
            }
        }
    }

    /// 溜めた変更があれば描き直す。リストが見えたときに画面が呼ぶ。
    func applyHeldChange() {
        guard hasHeldChange, !holdsChanges, isShown() else { return }
        hasHeldChange = false
        onRedrawNeeded()
    }
}
