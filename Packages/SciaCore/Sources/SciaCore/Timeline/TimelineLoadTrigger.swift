public import CoreGraphics

/// 一覧の続きを、どこまで近づいたら読ませるかを決める。末尾の続き（`FeedTimelineModel.approachEnd()`など、`approachEnd()`を持つ一覧のすべて）と、
/// ギャップ（`FeedTimelineModel.approachGap(_:from:)`）の両方。読み込みの間合いがUIによって変わらないよう、iOSとmacOSで同じ決まりを使う。
/// どの行を既読として報告するかは`ReadVisibility`が決める。
public enum TimelineLoadTrigger {
    /// 末尾から何行手前に入ったら、古い投稿を読み始めるか。
    public static let endThreshold = 10

    /// 行を表示したときに呼び、末尾に近ければtrueを返す。trueなら`approachEnd()`を呼ぶ。読んでいる最中に呼んでも、一覧は重ねて読まない。
    /// - Parameters:
    ///   - index: 表示した行の、一覧の中の位置。ギャップや読み込み中の行も1行に数える。
    ///   - count: 一覧の行の数。
    public static func isApproachingEnd(displaying index: Int, count: Int) -> Bool {
        index >= count - endThreshold
    }

    /// 使う人が一覧を動かしている向き。
    public enum ScrollDirection: Sendable {
        /// 上へ戻っている。新しい投稿の方へ向かっている。
        case towardNewer
        /// 下へ読み進めている。古い投稿の方へ向かっている。
        case towardOlder
    }

    /// 表示領域から`TuningCatalog.gapAutoLoadDistance`（表示領域の高さの何倍か）の距離に入ったギャップと、どちらの端から読むかを、渡した順に返す。
    /// それぞれを`approachGap(_:from:)`に渡す。スクロールするたびと、並びが変わるたびに呼ぶ。読んでいる最中のギャップは渡さない。
    ///
    /// 動かしている間は、上へ戻っているなら下の投稿に続く古い側から、下へ読み進めているなら上の投稿に続く新しい側から読ませる。
    /// 止まっているときは、表示領域の中央より上にあれば古い側から、下にあれば新しい側から読ませる。
    /// 止まった後の再接続などでできたギャップに、前の操作の向きを当てると、読んでいる投稿の反対側を基準にしてしまうため。
    /// - Parameters:
    ///   - gaps: ギャップの行と、その枠。
    ///   - visibleRect: 表示領域。ナビゲーションバーなどに隠れている部分は除いて渡す。
    ///   - scrollDirection: 指で動かしている間と、離したあとの慣性で動いている間は、最後に指で動かした向き。止まっていればnil。
    ///     向きは、スクロール位置の増減でなく指の動きから取る。上へ戻ると、見積もりから実寸へ変わった行の分を一覧が位置で補正し、位置が逆向きにも動くため。
    @MainActor
    public static func approachingGaps<ID>(
        _ gaps: [(id: ID, frame: CGRect)],
        in visibleRect: CGRect,
        scrollDirection: ScrollDirection?,
        tuning: TuningStore
    ) -> [(id: ID, direction: TimelineStore.GapDirection)] {
        let distance = tuning.value(of: TuningCatalog.gapAutoLoadDistance) * visibleRect.height
        let zone = visibleRect.insetBy(dx: 0, dy: -distance)
        return gaps.filter { $0.frame.intersects(zone) }.map { gap in
            let direction: TimelineStore.GapDirection = switch scrollDirection {
            case .towardNewer: .fromOlder
            case .towardOlder: .fromNewer
            case nil: gap.frame.midY < visibleRect.midY ? .fromOlder : .fromNewer
            }
            return (gap.id, direction)
        }
    }
}
