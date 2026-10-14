import QuartzCore
import SciaCore
import UIKit

/// 閉じたビューアの写しを、一覧のサムネイルへ戻す動き。ビューアを閉じたあと、操作を素通しする最前面の層で描く。
///
/// 戻る途中に一覧をスクロールされるとサムネイルが動くため、UIKitのアニメーションで行き先を決めると、古い位置へ戻ってから消えて見える。
/// 毎フレーム今のサムネイルを探し直し、始点とその位置のあいだをばねの進み具合で補う。
/// 途中で行が再利用されたら、隠すサムネイルも探し直したものに替える。見つからなくなったら、最後の位置へ向かいながら薄くする。
///
/// 最前面の写しは、一覧のバーに隠れない範囲にだけ見せる。バーの位置に見せると、バーの手前を通って貫通して見える。
/// バーの位置は、一覧の中に置いた同じ写し（`Underlay`）が埋める。一覧の中の写しにはバーの下のぼかしがかかるため、
/// 着地してサムネイルを見せても、バーにかかる部分の見え方が切り替わらない。
/// 閉じ始めにバーと重なっていた部分（縦長の画像や、下へ払ってタブバーにかかった画像）は、それまでバーより手前に描いていたため、
/// 急に奥へ移すと切り替わって見える。そこだけは閉じ始めの早いうちに薄くして、一覧の中の写しへ入れ替える。
/// 一覧の中の写しがないときは、見せる範囲を画面全体から一覧のバーに隠れない範囲へ、着地へ近づくにつれて絞る。
/// バーの下のぼかしはバーの下端より少し下までなだらかにかかり、新着ボタンのように一覧に重なる部品もあるため、
/// 着地の手前からは最前面の写しを薄くして、一覧の中の写しへ受け渡す。
@MainActor
final class MediaClosingFlight: NSObject {
    struct Parts {
        /// 写しや下地を載せる、操作を素通しする層。終わったら外す。
        let overlay: UIView
        let morph: UIImageView
        /// 写しに載せた、サムネイルの印の写し。
        let decoration: UIView?
        /// 一覧を暗くする下地。`fadingViews`にも含め、閉じながら薄くする。
        let backdrop: UIView
        let fadingViews: [UIView]
        /// バーの奥に描く写し。nilなら、バーにかかる部分を切り落とすだけにする。
        let underlay: Underlay?
    }

    /// 一覧の中に置き、最前面の写しと同じ位置と見た目で動かす写し。
    struct Underlay {
        let image: UIImageView
        let decoration: UIView?
    }

    private let parts: Parts
    private let window: UIWindow
    private let spring: SpringCurve
    private let movesImage: Bool
    private let handoffStart: CGFloat
    private let barOverlapFadeEnd: CGFloat
    /// 戻り先を見失ってから薄くしている度合い。1で不透明。
    private var visibility: CGFloat = 1
    private let findTile: @MainActor () -> MediaTileView?
    private let startFrame: CGRect
    private let startRadius: CGFloat
    private let startDecorationAlpha: CGFloat
    private let startFadingAlphas: [CGFloat]
    private var concealedTile: MediaTileView?
    private var lastTarget: (frame: CGRect, radius: CGFloat)?
    /// 戻り先の一覧の、バーに隠れない範囲（ウィンドウ座標）。見つかるまでは画面全体。
    private var lastVisibleRect: CGRect
    /// 最前面の写しのマスク。一覧のバーに隠れない範囲と、閉じ始めの写しの枠を重ねる。
    private let morphMask = CALayer()
    private let visibleMask = CALayer()
    private let startOverlapMask = CALayer()
    /// 最前面の写しを不透明に見せている範囲（ウィンドウ座標）。
    private var clipRect: CGRect
    /// 一覧の中の写しのマスク。最前面の写しを見せている範囲の外は不透明、内は受け渡しが始まるまで透明にする。
    private let underlayMask = CALayer()
    private let underlayOutsideMask = CAShapeLayer()
    private let underlayInsideMask = CALayer()
    /// 下地のマスク。一覧の中の写しを描くとき、写しの枠に穴を開ける。
    private let backdropMask = CALayer()
    private let backdropOutsideMask = CAShapeLayer()
    /// 穴の中で、画像の透明な部分にだけ下地を残す。画像の透明度を反転した画像を、写しと同じ切り抜き方で描く。
    private let backdropHoleFill = CALayer()
    /// `backdropHoleFill`に描いている、反転の元にした画像。
    private weak var holeFillSource: UIImage?
    /// バーの奥の写しを載せる、戻り先のサムネイルを含む一覧の行。
    private weak var underlayHost: UIView?
    private var startTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    /// - Parameters:
    ///   - concealedTile: 戻り先として隠しているサムネイル。戻り終えたら見せる。
    ///   - handoffStart: 一覧の中の写しへ受け渡し始める進み具合。一覧の中の写しがなければ使わない。
    ///   - barOverlapFadeEnd: 閉じ始めにバーと重なっていた部分を、一覧の中の写しへ入れ替え終える進み具合。一覧の中の写しがなければ使わない。
    ///   - movesImage: falseなら写しを動かさず、その場で薄くする。
    init(
        parts: Parts,
        window: UIWindow,
        spring: SpringCurve,
        handoffStart: CGFloat,
        barOverlapFadeEnd: CGFloat,
        movesImage: Bool,
        concealedTile: MediaTileView?,
        findTile: @escaping @MainActor () -> MediaTileView?
    ) {
        self.parts = parts
        self.window = window
        self.spring = spring
        self.handoffStart = min(max(handoffStart, 0), 1)
        self.barOverlapFadeEnd = min(max(barOverlapFadeEnd, 0.01), 1)
        self.movesImage = movesImage
        self.concealedTile = concealedTile
        self.findTile = findTile
        startFrame = parts.morph.frame
        startRadius = parts.morph.layer.cornerRadius
        startDecorationAlpha = parts.decoration?.alpha ?? 0
        startFadingAlphas = parts.fadingViews.map(\.alpha)
        lastVisibleRect = window.bounds
        clipRect = window.bounds
        visibleMask.backgroundColor = UIColor.black.cgColor
        startOverlapMask.backgroundColor = UIColor.black.cgColor
        morphMask.addSublayer(visibleMask)
        morphMask.addSublayer(startOverlapMask)
        parts.morph.layer.mask = morphMask
        underlayOutsideMask.fillColor = UIColor.black.cgColor
        underlayOutsideMask.fillRule = .evenOdd
        underlayInsideMask.backgroundColor = UIColor.black.cgColor
        underlayMask.addSublayer(underlayOutsideMask)
        underlayMask.addSublayer(underlayInsideMask)
        parts.underlay?.image.layer.mask = underlayMask
        if parts.underlay != nil {
            backdropOutsideMask.fillColor = UIColor.black.cgColor
            backdropOutsideMask.fillRule = .evenOdd
            backdropHoleFill.contentsGravity = .resizeAspectFill
            backdropHoleFill.masksToBounds = true
            backdropMask.addSublayer(backdropOutsideMask)
            backdropMask.addSublayer(backdropHoleFill)
            parts.backdrop.layer.mask = backdropMask
        }
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
            if let (scrollView, row) = Self.enclosingRow(of: tile) {
                underlayHost = row
                lastVisibleRect = scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: window)
            }
        }
        if movesImage, let target = lastTarget {
            parts.morph.frame = Self.interpolate(startFrame, target.frame, progress)
            parts.morph.layer.cornerRadius = startRadius + (target.radius - startRadius) * clamped
            parts.decoration?.alpha = startDecorationAlpha + (1 - startDecorationAlpha) * clamped
            if tile == nil {
                // 戻り先が画面から外れたら、最後の位置へ向かいながら薄くする。
                visibility = min(visibility, 1 - clamped)
            }
        } else {
            visibility = 1 - clamped
        }
        let handoff = handoff(progress: clamped)
        parts.morph.alpha = visibility * (1 - handoff)
        updateClip(progress: clamped)
        updateUnderlay(handoff: handoff)
        updateBackdropHole()
        for (view, startAlpha) in zip(parts.fadingViews, startFadingAlphas) {
            view.alpha = startAlpha * (1 - clamped)
        }
    }

    /// 最前面の写しを見せる範囲を決める。一覧の外の最前面で動かしているため、バーの位置に見せると手前を通って貫通して見える。
    private func updateClip(progress: CGFloat) {
        let startOverlapOpacity: CGFloat
        if parts.underlay != nil {
            // バーの位置は一覧の中の写しが埋めるため、見せるのは一覧のバーに隠れない範囲と、閉じ始めにすでに描いていた枠だけにする。
            clipRect = lastVisibleRect
            let t = min(progress / barOverlapFadeEnd, 1)
            startOverlapOpacity = 1 - t * t * (3 - 2 * t)
        } else {
            clipRect = Self.interpolate(window.bounds, lastVisibleRect, progress)
            startOverlapOpacity = 0
        }
        let origin = parts.morph.frame.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        visibleMask.frame = clipRect.offsetBy(dx: -origin.x, dy: -origin.y)
        startOverlapMask.frame = startFrame.intersection(window.bounds).offsetBy(dx: -origin.x, dy: -origin.y)
        startOverlapMask.opacity = Float(startOverlapOpacity)
        CATransaction.commit()
    }

    /// 最前面の写しを一覧の中の写しへ受け渡した度合い。0で最前面の写しだけ、1で一覧の中の写しだけが見える。
    private func handoff(progress: CGFloat) -> CGFloat {
        guard parts.underlay != nil, underlayHost != nil else { return 0 }
        guard handoffStart < 1 else { return progress >= 1 ? 1 : 0 }
        let t = min(max((progress - handoffStart) / (1 - handoffStart), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// バーの奥の写しを、最前面の写しと同じ位置と見た目にそろえる。
    /// 写しは行からはみ出すため、行をほかの行より手前に描く。`zPosition`を上げるとバーの下のぼかしより手前に出てしまうため、
    /// 同じ`zPosition`の行どうしの並び順で手前に出す。一覧は行を足すときに並び順を変えるため、毎フレーム出し直す。
    /// 最前面の写しを不透明に見せている範囲では、受け渡しが始まるまで透明にし、半透明の画像で2枚の写しが重なって濃く見えないようにする。
    /// 閉じ始めにバーと重なっていた部分では不透明のままにする。そこでは最前面の写しを薄くして入れ替えるため、半透明の画像はその間だけ濃く見える。
    /// 受け渡しの間は2枚を重ねる。不透明な画像は、下の写しを不透明にしないと重ねた結果が薄くなる（上を1-h、下をhの濃さにすると1-h+h²）。
    /// そのため下の写しは受け渡しの始めにすばやく不透明にし、不透明な画像が薄く見えるのを数%に抑える。
    /// 代わりに半透明の画像では、受け渡しの間（既定で閉じる時間の最後の3割）だけ半透明の部分が濃く見える。添付の多くは不透明な写真なので、こちらを受け入れる。
    private func updateUnderlay(handoff: CGFloat) {
        guard let underlay = parts.underlay, let host = underlayHost else { return }
        if let list = host.superview, list.subviews.last !== host {
            list.bringSubviewToFront(host)
        }
        let image = underlay.image
        if image.superview !== host {
            host.addSubview(image)
        } else if host.subviews.last !== image {
            host.bringSubviewToFront(image)
        }
        let morph = parts.morph
        if image.image !== morph.image {
            image.image = morph.image
        }
        image.frame = host.convert(morph.frame, from: window)
        image.layer.cornerRadius = morph.layer.cornerRadius
        image.alpha = visibility
        underlay.decoration?.alpha = parts.decoration?.alpha ?? 0
        let bounds = image.bounds
        let inside = image.convert(clipRect, from: window).intersection(bounds)
        let outside = UIBezierPath(rect: bounds)
        if !inside.isNull {
            outside.append(UIBezierPath(rect: inside))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underlayMask.frame = bounds
        underlayOutsideMask.frame = bounds
        underlayOutsideMask.path = outside.cgPath
        underlayInsideMask.frame = inside.isNull ? .zero : inside
        underlayInsideMask.opacity = Float(min(handoff / Self.underlayFadeInPortion, 1))
        CATransaction.commit()
    }

    /// 下地のうち写しのある部分に穴を開ける。一覧の中の写しは下地の奥にあるため、穴がないと、
    /// 最前面の写しから入れ替えた部分（バーと重なっていた部分や、着地手前の受け渡し）だけが暗く見え、境目ができる。
    /// 写しはビューアの画像として下地より手前にあるものなので、どちらの写しを見せていても暗くしない。
    /// 画像の透明な部分は、開いている間も下地の上に描いていたため、そこには下地を残す。
    private func updateBackdropHole() {
        guard parts.underlay != nil else { return }
        let backdrop = parts.backdrop
        let morph = parts.morph
        let hole = backdrop.convert(morph.frame, from: morph.superview)
        let radius = morph.layer.cornerRadius
        let path = UIBezierPath(rect: backdrop.bounds)
        path.append(UIBezierPath(roundedRect: hole, cornerRadius: radius))
        if morph.image !== holeFillSource {
            holeFillSource = morph.image
            backdropHoleFill.contents = morph.image.flatMap(Self.inverseAlphaImage)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropMask.frame = backdrop.bounds
        backdropOutsideMask.frame = backdrop.bounds
        backdropOutsideMask.path = path.cgPath
        backdropHoleFill.frame = hole
        backdropHoleFill.cornerRadius = radius
        backdropHoleFill.cornerCurve = morph.layer.cornerCurve
        CATransaction.commit()
    }

    /// 透明度を反転した画像。不透明な部分が透明に、透明な部分が不透明になる。透明度を持たない画像ならnilで、穴を開けきる。
    /// マスクに使うだけなので、長辺を512pxに縮めて作る。
    static func inverseAlphaImage(of image: UIImage) -> CGImage? {
        guard let alpha = image.cgImage?.alphaInfo else { return nil }
        switch alpha {
        case .none, .noneSkipFirst, .noneSkipLast:
            return nil
        default:
            break
        }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(512 / longest, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size), blendMode: .destinationOut, alpha: 1)
        }.cgImage
    }

    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        parts.overlay.removeFromSuperview()
        parts.underlay?.image.removeFromSuperview()
        concealedTile?.isConcealedForViewer = false
        concealedTile = nil
    }

    /// 受け渡しの度合いのうち、最前面の写しを見せている範囲で一覧の中の写しを不透明にし終えるまでの割合。
    private static let underlayFadeInPortion: CGFloat = 0.15

    /// サムネイルを含む一覧と、その一覧の直下にある行。
    private static func enclosingRow(of view: UIView) -> (UIScrollView, UIView)? {
        var row = view
        while let parent = row.superview {
            if let scrollView = parent as? UIScrollView {
                return (scrollView, row)
            }
            row = parent
        }
        return nil
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
