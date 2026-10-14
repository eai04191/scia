import QuartzCore
import SciaCore
import UIKit

/// 閉じたビューアの写しを、一覧のサムネイルへ戻す動き。ビューアを閉じたあと、操作を素通しする最前面の層で描く。
///
/// 戻る途中に一覧をスクロールされるとサムネイルが動くため、UIKitのアニメーションで行き先を決めると、古い位置へ戻ってから消えて見える。
/// 毎フレーム今のサムネイルを探し直し、始点とその位置のあいだをばねの進み具合で補う。
/// 途中で行が再利用されたら、隠すサムネイルも探し直したものに替える。見つからなくなったら、最後の位置へ向かいながら薄くする。
@MainActor
final class MediaClosingFlight: NSObject {
    struct Parts {
        /// 写しや下地を載せる、操作を素通しする層。終わったら外す。
        let overlay: UIView
        let morph: UIView
        /// 写しに載せた、サムネイルの印の写し。
        let decoration: UIView?
        let fadingViews: [UIView]
    }

    private let parts: Parts
    private let window: UIWindow
    private let spring: SpringCurve
    private let movesImage: Bool
    private let findTile: @MainActor () -> MediaTileView?
    private let startFrame: CGRect
    private let startRadius: CGFloat
    private let startDecorationAlpha: CGFloat
    private let startFadingAlphas: [CGFloat]
    private var concealedTile: MediaTileView?
    private var lastTarget: (frame: CGRect, radius: CGFloat)?
    private var startTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    /// - Parameters:
    ///   - concealedTile: 戻り先として隠しているサムネイル。戻り終えたら見せる。
    ///   - movesImage: falseなら写しを動かさず、その場で薄くする。
    init(
        parts: Parts,
        window: UIWindow,
        spring: SpringCurve,
        movesImage: Bool,
        concealedTile: MediaTileView?,
        findTile: @escaping @MainActor () -> MediaTileView?
    ) {
        self.parts = parts
        self.window = window
        self.spring = spring
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
        if tile !== concealedTile {
            concealedTile?.isConcealedForViewer = false
            tile?.isConcealedForViewer = true
            concealedTile = tile
        }
        if let tile {
            lastTarget = (tile.convert(tile.bounds, to: window), tile.layer.cornerRadius)
        }
        if movesImage, let target = lastTarget {
            parts.morph.frame = Self.interpolate(startFrame, target.frame, progress)
            parts.morph.layer.cornerRadius = startRadius + (target.radius - startRadius) * clamped
            parts.decoration?.alpha = startDecorationAlpha + (1 - startDecorationAlpha) * clamped
            if tile == nil {
                // 戻り先が画面から外れたら、最後の位置へ向かいながら薄くする。
                parts.morph.alpha = min(parts.morph.alpha, 1 - clamped)
            }
        } else {
            parts.morph.alpha = 1 - clamped
        }
        for (view, startAlpha) in zip(parts.fadingViews, startFadingAlphas) {
            view.alpha = startAlpha * (1 - clamped)
        }
    }

    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        parts.overlay.removeFromSuperview()
        concealedTile?.isConcealedForViewer = false
        concealedTile = nil
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
