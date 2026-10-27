import QuartzCore
import SciaCore
import UIKit

/// 閉じたビューアの複製を、一覧のサムネイルへ戻す動き。ビューアを閉じたあと、操作を素通しする最前面の層で描く。
///
/// 戻る途中に一覧をスクロールされるとサムネイルが動くため、UIKitのアニメーションで行き先を決めると、古い位置へ戻ってから消えて見える。
/// 毎フレーム今のサムネイルを探し直し、始点とその位置のあいだをスプリングの進み具合で補う。
/// 途中で行が再利用されたら、隠すサムネイルも探し直したものに替える。見つからなくなったら、最後の位置へ向かいながら薄くする。
///
/// 複製をバーの手前と奥に描き分ける仕組みは`MediaBarLayering`にある。閉じ始めにバーと重なっていた部分（縦長の画像や、下へスワイプしてタブバーにかかった画像）は、
/// それまでバーより手前に描いていたため、急に奥へ移すと切り替わって見える。そこだけは閉じ始めの早いうちに薄くして、一覧の中の複製へ入れ替える。
/// 着地の手前からは最前面の複製全体を薄くして、一覧の中の複製へ受け渡す。
/// 一覧の中の複製がないときは、見せる範囲を画面全体から一覧のバーに隠れない範囲へ、着地へ近づくにつれて絞る。
@MainActor
final class MediaClosingFlight {
    struct Parts {
        /// 複製や下地を載せる、操作を素通しする層。終わったら外す。
        let overlay: UIView
        let morph: FocusCroppedImageView
        /// 複製に載せた、サムネイルに重ねた表示の複製。
        let decoration: UIView?
        /// 複製のさらに手前に置いた、サムネイルに重なっているビューの複製。重ねた表示と同じ濃さで出し入れする。
        let overlap: MediaSourceOverlap?
        /// 複製に敷く、サムネイルの背景の色。重ねた表示と同じ濃さで出し入れする。
        let placeholderColor: UIColor?
        /// 一覧を暗くする下地。`fadingViews`にも含め、閉じながら薄くする。
        let backdrop: UIView
        let fadingViews: [UIView]
        /// 複製をバーの手前と奥に描き分ける。一覧の中の複製を持たなければ、バーにかかる部分を切り落とすだけにする。
        let layering: MediaBarLayering
    }

    private let parts: Parts
    private let window: UIWindow
    private let spring: SpringCurve
    private let movesImage: Bool
    private let handoffStart: CGFloat
    private let barOverlapFadeEnd: CGFloat
    /// 閉じ始めに、バーと重なっていた部分を手前に見せていた濃さ。
    private let startOverlapOpacity: CGFloat
    /// 戻り先を見失ってから薄くしている度合い。1で不透明。
    private var visibility: CGFloat = 1
    private let findTile: @MainActor () -> (any MediaViewerSource)?
    /// 回転を戻したときの、閉じ始めの複製の枠。
    private let startFrame: CGRect
    /// 閉じ始めの複製が画面で占めていた範囲。回っていれば、回した角まで含む外側の四角。
    /// 閉じ始めにバーと重なっていた部分を、手前に見せたまま薄くするのに使う。回転を戻した枠では、はみ出た角がすぐにバーの奥へ切り替わるため。
    private let startCoveredFrame: CGRect
    /// 閉じ始めの複製の角度。開く途中から閉じるときは、回した起点から始めていれば0でないことがある。
    private let startRotation: CGFloat
    private let startRadius: CGFloat
    /// 閉じ始めの複製の白いフチの幅。ふつうは0で、開く途中から閉じるときだけ残っている。
    private let startBorder: CGFloat
    /// 閉じ始めの複製の、中身の濃さと暗さ。
    private let startAppearance: (contentOpacity: CGFloat, dimming: CGFloat)
    /// 写真の白いフチを太くし始めてから着くまでの、動きの進み具合の幅。後半で太くし、広がった画像を細い線が囲まないようにする。
    private let paperBorderPortion: CGFloat
    private let startDecorationAlpha: CGFloat
    private let startFadingAlphas: [CGFloat]
    private var concealedTile: (any MediaViewerSource)?
    /// 戻り先の、回転を戻したときの枠、角度、角の丸み。回した起点（一覧で重ねた写真）へは、その角度まで回しながら戻す。
    private var lastTarget: (frame: CGRect, rotation: CGFloat, radius: CGFloat, border: CGFloat, appearance: (contentOpacity: CGFloat, dimming: CGFloat))?
    private let source: any FrameSource
    /// 戻り始めてからの時間。
    private var time: CFTimeInterval = 0
    private var ticker: FrameTicker?
    /// 戻り終えたときに呼ぶ。
    var onFinish: (() -> Void)?

    /// - Parameters:
    ///   - concealedTile: 戻り先として隠しているサムネイル。戻り終えたら見せる。
    ///   - handoffStart: 一覧の中の複製へ受け渡し始める進み具合。一覧の中の複製がなければ使わない。
    ///   - barOverlapFadeEnd: 閉じ始めにバーと重なっていた部分を、一覧の中の複製へ入れ替え終える進み具合。一覧の中の複製がなければ使わない。
    ///   - startOverlapOpacity: 閉じ始めに、バーと重なっていた部分を手前に見せていた濃さ。開く途中から閉じるときは1未満になる。
    ///   - movesImage: falseなら複製を動かさず、その場で薄くする。
    ///   - paperBorderPortion: 写真の白いフチ（一覧で重ねた写真）を、着く手前のこの進み具合の幅で太くする。
    ///   - source: 経過時間を送る元。テストでは、実際の時間に頼らずに動きを進めるため、手で送る元を渡す。
    init(
        parts: Parts,
        window: UIWindow,
        spring: SpringCurve,
        handoffStart: CGFloat,
        barOverlapFadeEnd: CGFloat,
        startOverlapOpacity: CGFloat,
        movesImage: Bool,
        paperBorderPortion: CGFloat = 1,
        concealedTile: (any MediaViewerSource)?,
        source: any FrameSource = DisplayLinkFrameSource.shared,
        findTile: @escaping @MainActor () -> (any MediaViewerSource)?
    ) {
        self.parts = parts
        self.window = window
        self.spring = spring
        self.handoffStart = min(max(handoffStart, 0), 1)
        self.barOverlapFadeEnd = min(max(barOverlapFadeEnd, 0.01), 1)
        self.startOverlapOpacity = startOverlapOpacity
        self.movesImage = movesImage
        self.paperBorderPortion = min(max(paperBorderPortion, 0.01), 1)
        self.concealedTile = concealedTile
        self.source = source
        self.findTile = findTile
        startFrame = parts.morph.unrotatedFrame
        startCoveredFrame = parts.morph.frame
        startRotation = parts.morph.transformRotation
        startRadius = parts.morph.layer.cornerRadius
        startBorder = parts.morph.paperBorder
        startAppearance = (parts.morph.contentOpacity, parts.morph.dimming)
        startDecorationAlpha = parts.decoration?.alpha ?? 0
        startFadingAlphas = parts.fadingViews.map(\.alpha)
    }

    func start() {
        // スプリングは決まった時間で落ち着くため、ひっかかりで間が空いても経過時間を削らず、描かれる時刻とそろえる。
        // 閉じたビューアはこれを持たないため、戻り終えるまで自分を強く持つ。戻り終えると`ticker`を手放して解く。
        let ticker = FrameTicker(source: source, longestElapsed: nil) { elapsed in
            self.step(elapsed: elapsed)
        }
        self.ticker = ticker
        ticker.start()
        update(time: 0)
    }

    private func step(elapsed: CFTimeInterval) -> Bool {
        time += elapsed
        update(time: time)
        guard spring.isSettled(at: time) else { return true }
        finish()
        return false
    }

    private func update(time: CFTimeInterval) {
        let progress = CGFloat(spring.value(at: time))
        let clamped = min(max(progress, 0), 1)
        let tile = findTile()
        // 複製を動かさないときは、複製がサムネイルへ戻らないため隠さない。隠すと、複製が消えてからサムネイルが急に現れる。
        let tileToConceal = movesImage ? tile : nil
        if tileToConceal !== concealedTile {
            concealedTile?.isConcealedForViewer = false
            tileToConceal?.isConcealedForViewer = true
            concealedTile = tileToConceal
        }
        if let tile {
            // 白いフチの付いた起点（一覧で重ねた写真）へは、フチを含めた写真の枠と角の丸みへ、フチを太くしながら戻す。
            // 縮めて置いた起点（一覧で傾けずに重ねた奥の写真）へは、フチと角の丸みも同じ倍率で細くして戻す。
            let paper = tile.paperBorder
            let scale = tile.scale(in: window)
            let border = (paper?.width ?? 0) * scale
            lastTarget = (tile.unrotatedFrame(in: window).insetBy(dx: -border, dy: -border), tile.rotation(in: window), (paper?.cornerRadius ?? tile.layer.cornerRadius) * scale, border, tile.viewerAppearance)
            parts.morph.layer.maskedCorners = tile.layer.maskedCorners
            parts.layering.track(tile)
            parts.overlap?.follow(tile)
        }
        if movesImage, let target = lastTarget {
            parts.morph.place(unrotatedFrame: Self.interpolate(startFrame, target.frame, progress), rotation: startRotation + (target.rotation - startRotation) * progress)
            parts.morph.layer.cornerRadius = startRadius + (target.radius - startRadius) * clamped
            let borderProgress = min(max((clamped - (1 - paperBorderPortion)) / paperBorderPortion, 0), 1)
            parts.morph.paperBorder = startBorder + (target.border - startBorder) * borderProgress
            parts.decoration?.frame = parts.morph.bounds.insetBy(dx: parts.morph.paperBorder, dy: parts.morph.paperBorder)
            // フチを太くするのと同じ区間で、戻り先の見え方（中身を描かない、暗くする）へ移す。着いたところで見え方が急に替わらないようにする。
            parts.morph.contentOpacity = startAppearance.contentOpacity + (target.appearance.contentOpacity - startAppearance.contentOpacity) * borderProgress
            parts.morph.dimming = startAppearance.dimming + (target.appearance.dimming - startAppearance.dimming) * borderProgress
            let decorationAlpha = startDecorationAlpha + (1 - startDecorationAlpha) * clamped
            parts.decoration?.alpha = decorationAlpha
            parts.morph.backgroundColor = MediaViewerController.placeholderColor(parts.placeholderColor, alpha: decorationAlpha)
            if tile == nil {
                // 戻り先が画面から外れたら、最後の位置へ向かいながら薄くする。
                visibility = min(visibility, 1 - clamped)
            }
            // 一覧の中の複製へ受け渡す間も、受け渡した複製の手前に重なって見えるよう、複製の濃さとは別に出す。
            parts.overlap?.view.alpha = decorationAlpha * visibility
        } else {
            visibility = 1 - clamped
            parts.overlap?.view.alpha = 0
        }
        let layering = parts.layering
        if layering.drawsUnderBars {
            // バーの位置は一覧の中の複製が埋めるため、最前面の複製を見せるのは一覧のバーに隠れない範囲と、閉じ始めにすでに描いていた枠だけにする。
            let swap = MediaBarSwap.closing(
                progress: clamped,
                handoffStart: handoffStart,
                overlapFadeEnd: barOverlapFadeEnd,
                startOverlapOpacity: startOverlapOpacity
            )
            parts.morph.alpha = visibility * (1 - swap.handoff)
            layering.apply(clipRect: layering.visibleRect, overlapRect: startCoveredFrame, swap: swap, visibility: visibility)
        } else {
            parts.morph.alpha = visibility
            let clipRect = Self.interpolate(window.bounds, layering.visibleRect, clamped)
            layering.apply(clipRect: clipRect, overlapRect: .zero, swap: MediaBarSwap(handoff: 0, overlapOpacity: 0), visibility: visibility)
        }
        for (view, startAlpha) in zip(parts.fadingViews, startFadingAlphas) {
            view.alpha = startAlpha * (1 - clamped)
        }
    }

    private func finish() {
        ticker?.stop()
        ticker = nil
        parts.overlay.removeFromSuperview()
        parts.layering.tearDown()
        concealedTile?.isConcealedForViewer = false
        concealedTile = nil
        onFinish?()
    }

    private static func interpolate(_ from: CGRect, _ to: CGRect, _ progress: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress
        )
    }
}
