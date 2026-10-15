import QuartzCore
import SciaCore
import UIKit

/// 閉じたビューアの写しを、一覧のサムネイルへ戻す動き。ビューアを閉じたあと、操作を素通しする最前面の層で描く。
///
/// 戻る途中に一覧をスクロールされるとサムネイルが動くため、UIKitのアニメーションで行き先を決めると、古い位置へ戻ってから消えて見える。
/// 毎フレーム今のサムネイルを探し直し、始点とその位置のあいだをばねの進み具合で補う。
/// 途中で行が再利用されたら、隠すサムネイルも探し直したものに替える。見つからなくなったら、最後の位置へ向かいながら薄くする。
///
/// 写しをバーの手前と奥に描き分ける仕組みは`MediaBarLayering`にある。閉じ始めにバーと重なっていた部分（縦長の画像や、下へ払ってタブバーにかかった画像）は、
/// それまでバーより手前に描いていたため、急に奥へ移すと切り替わって見える。そこだけは閉じ始めの早いうちに薄くして、一覧の中の写しへ入れ替える。
/// 着地の手前からは最前面の写し全体を薄くして、一覧の中の写しへ受け渡す。
/// 一覧の中の写しがないときは、見せる範囲を画面全体から一覧のバーに隠れない範囲へ、着地へ近づくにつれて絞る。
@MainActor
final class MediaClosingFlight: NSObject {
    struct Parts {
        /// 写しや下地を載せる、操作を素通しする層。終わったら外す。
        let overlay: UIView
        let morph: UIImageView
        /// 写しに載せた、サムネイルの印の写し。
        let decoration: UIView?
        /// 写しに敷く、サムネイルの背景の色。印と同じ濃さで出し入れする。
        let placeholderColor: UIColor?
        /// 一覧を暗くする下地。`fadingViews`にも含め、閉じながら薄くする。
        let backdrop: UIView
        let fadingViews: [UIView]
        /// 写しをバーの手前と奥に描き分ける。一覧の中の写しを持たなければ、バーにかかる部分を切り落とすだけにする。
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
    private let findTile: @MainActor () -> MediaTileView?
    private let startFrame: CGRect
    private let startRadius: CGFloat
    private let startDecorationAlpha: CGFloat
    private let startFadingAlphas: [CGFloat]
    private var concealedTile: MediaTileView?
    private var lastTarget: (frame: CGRect, radius: CGFloat)?
    private var startTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    /// 戻り終えたときに呼ぶ。
    var onFinish: (() -> Void)?

    /// - Parameters:
    ///   - concealedTile: 戻り先として隠しているサムネイル。戻り終えたら見せる。
    ///   - handoffStart: 一覧の中の写しへ受け渡し始める進み具合。一覧の中の写しがなければ使わない。
    ///   - barOverlapFadeEnd: 閉じ始めにバーと重なっていた部分を、一覧の中の写しへ入れ替え終える進み具合。一覧の中の写しがなければ使わない。
    ///   - startOverlapOpacity: 閉じ始めに、バーと重なっていた部分を手前に見せていた濃さ。開く途中から閉じるときは1未満になる。
    ///   - movesImage: falseなら写しを動かさず、その場で薄くする。
    init(
        parts: Parts,
        window: UIWindow,
        spring: SpringCurve,
        handoffStart: CGFloat,
        barOverlapFadeEnd: CGFloat,
        startOverlapOpacity: CGFloat,
        movesImage: Bool,
        concealedTile: MediaTileView?,
        findTile: @escaping @MainActor () -> MediaTileView?
    ) {
        self.parts = parts
        self.window = window
        self.spring = spring
        self.handoffStart = min(max(handoffStart, 0), 1)
        self.barOverlapFadeEnd = min(max(barOverlapFadeEnd, 0.01), 1)
        self.startOverlapOpacity = startOverlapOpacity
        self.movesImage = movesImage
        self.concealedTile = concealedTile
        self.findTile = findTile
        startFrame = parts.morph.frame
        startRadius = parts.morph.layer.cornerRadius
        startDecorationAlpha = parts.decoration?.alpha ?? 0
        startFadingAlphas = parts.fadingViews.map(\.alpha)
    }

    func start() {
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        update(time: 0)
    }

    @objc private func step(_ link: CADisplayLink) {
        let time = link.targetTimestamp - startTime
        update(time: time)
        if spring.isSettled(at: time) {
            finish()
        }
    }

    private func update(time: CFTimeInterval) {
        let progress = CGFloat(spring.value(at: time))
        let clamped = min(max(progress, 0), 1)
        let tile = findTile()
        // 写しを動かさないときは、写しがサムネイルへ戻らないため隠さない。隠すと、写しが消えてからサムネイルが急に現れる。
        let tileToConceal = movesImage ? tile : nil
        if tileToConceal !== concealedTile {
            concealedTile?.isConcealedForViewer = false
            tileToConceal?.isConcealedForViewer = true
            concealedTile = tileToConceal
        }
        if let tile {
            lastTarget = (tile.convert(tile.bounds, to: window), tile.layer.cornerRadius)
            parts.layering.track(tile)
        }
        if movesImage, let target = lastTarget {
            parts.morph.frame = Self.interpolate(startFrame, target.frame, progress)
            parts.morph.layer.cornerRadius = startRadius + (target.radius - startRadius) * clamped
            let decorationAlpha = startDecorationAlpha + (1 - startDecorationAlpha) * clamped
            parts.decoration?.alpha = decorationAlpha
            parts.morph.backgroundColor = MediaViewerController.placeholderColor(parts.placeholderColor, alpha: decorationAlpha)
            if tile == nil {
                // 戻り先が画面から外れたら、最後の位置へ向かいながら薄くする。
                visibility = min(visibility, 1 - clamped)
            }
        } else {
            visibility = 1 - clamped
        }
        let layering = parts.layering
        if layering.drawsUnderBars {
            // バーの位置は一覧の中の写しが埋めるため、最前面の写しを見せるのは一覧のバーに隠れない範囲と、閉じ始めにすでに描いていた枠だけにする。
            let swap = MediaBarSwap.closing(
                progress: clamped,
                handoffStart: handoffStart,
                overlapFadeEnd: barOverlapFadeEnd,
                startOverlapOpacity: startOverlapOpacity
            )
            parts.morph.alpha = visibility * (1 - swap.handoff)
            layering.apply(clipRect: layering.visibleRect, overlapRect: startFrame, swap: swap, visibility: visibility)
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
        displayLink?.invalidate()
        displayLink = nil
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
