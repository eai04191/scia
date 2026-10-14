import QuartzCore
import SciaCore
import UIKit

/// ビューアの開閉で、画像の写しを一覧のバーの手前と奥に描き分ける。写しを動かすたびに、同じフレームで`apply`を呼ぶ。
///
/// 最前面の写し（ビューアや閉じる動きの層に置く、バーより手前の写し）は、一覧のバーに隠れない範囲と、指定した重なりの枠にだけ見せる。
/// バーの位置に見せると、バーの手前を通って貫通して見えるため。
/// バーの位置は、一覧の中に置いた同じ写し（`Underlay`）が埋める。一覧の中の写しにはバーの下のぼかしがかかるため、
/// サムネイルの位置でも、バーにかかる部分の見え方がサムネイルとそろう。
/// iOS 26のバーの下のぼかし（scroll edge effect）は、一覧の行（セル）の中身だけを取り込む。コレクションビューの直下に足したビューには
/// かからないため、写しはサムネイルを含む一覧の行の中に置く。
/// バーの`alpha`を下げて写しをバーより手前に見せる方法は使えない。UIKitがナビゲーションバーとタブバーの`alpha`を戻すため、
/// 開いているビューアの上にバーが透けて見えた。
/// バーの下のぼかしはバーの下端より少し下までなだらかにかかり、新着ボタンのように一覧に重なる部品もあるため、
/// サムネイルに近い間は、バーに隠れない範囲でも一覧の中の写しを見せる（受け渡し）。
/// バーと重なる部分は、2枚の写しの濃さを入れ替える。入れ替えの途中は、最前面の写しがバーの部品（タブバーのピルなど）の上に半透明で重なる。
/// 下地の穴をバーに隠れない範囲に限り、入れ替えを暗い下地の奥で済ませる方法も試したが、バーの位置にあたる画面幅いっぱいの帯が
/// 下地の濃さで暗くなり、録画で見比べてこちらを選んだ。
@MainActor
final class MediaBarLayering {
    /// 一覧の中に置き、最前面の写しと同じ位置と見た目で動かす写し。
    struct Underlay {
        let image: UIImageView
        let decoration: UIView?
    }

    private let morph: UIImageView
    /// 最前面の写しに載せた、サムネイルの印の写し。
    private let decoration: UIView?
    private let backdrop: UIView
    /// nilなら、最前面の写しの見せる範囲を絞るだけにする。
    private let underlay: Underlay?
    private let window: UIWindow
    /// サムネイルを含む一覧の、バーに隠れない範囲（ウィンドウ座標）。見つかるまでは画面全体。
    private(set) var visibleRect: CGRect
    /// 一覧の中の写しを載せる、サムネイルを含む一覧の行。
    private weak var underlayHost: UIView?
    /// 最前面の写しのマスク。不透明に見せる範囲と、重なりの枠を重ねる。
    private let morphMask = CALayer()
    private let clipMask = CALayer()
    private let overlapMask = CALayer()
    /// 一覧の中の写しのマスク。最前面の写しを不透明に見せている範囲の外は不透明、内は受け渡しの度合いで濃くする。
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

    init(morph: UIImageView, decoration: UIView?, backdrop: UIView, underlay: Underlay?, window: UIWindow) {
        self.morph = morph
        self.decoration = decoration
        self.backdrop = backdrop
        self.underlay = underlay
        self.window = window
        visibleRect = window.bounds
        clipMask.backgroundColor = UIColor.black.cgColor
        overlapMask.backgroundColor = UIColor.black.cgColor
        morphMask.addSublayer(clipMask)
        morphMask.addSublayer(overlapMask)
        morph.layer.mask = morphMask
        guard let underlay else { return }
        underlayOutsideMask.fillColor = UIColor.black.cgColor
        underlayOutsideMask.fillRule = .evenOdd
        underlayInsideMask.backgroundColor = UIColor.black.cgColor
        underlayMask.addSublayer(underlayOutsideMask)
        underlayMask.addSublayer(underlayInsideMask)
        underlay.image.layer.mask = underlayMask
        backdropOutsideMask.fillColor = UIColor.black.cgColor
        backdropOutsideMask.fillRule = .evenOdd
        backdropHoleFill.contentsGravity = .resizeAspectFill
        backdropHoleFill.masksToBounds = true
        backdropMask.addSublayer(backdropOutsideMask)
        backdropMask.addSublayer(backdropHoleFill)
        backdrop.layer.mask = backdropMask
    }

    /// 一覧の中の写しを描けるか。サムネイルを含む一覧の行が見つかっていなければ描けない。
    var drawsUnderBars: Bool {
        underlay != nil && underlayHost != nil
    }

    /// サムネイルから、一覧の中の写しを載せる行と、一覧のバーに隠れない範囲を探し直す。
    func track(_ tile: MediaTileView) {
        guard let (scrollView, row) = Self.enclosingRow(of: tile) else { return }
        underlayHost = row
        visibleRect = scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: window)
    }

    /// 最前面の写しの今の位置と見た目に合わせて、2枚の写しと下地の穴を描き直す。最前面の写しの`alpha`は呼び出し側で決める。
    /// - Parameters:
    ///   - clipRect: 最前面の写しを不透明に見せる範囲。ウィンドウ座標。
    ///   - overlapRect: `clipRect`のほかに、最前面の写しを`swap.overlapOpacity`の濃さで見せる枠。ウィンドウ座標。
    ///   - visibility: 写しの濃さ。戻り先を見失って薄くするときに1未満にする。
    func apply(clipRect: CGRect, overlapRect: CGRect, swap: MediaBarSwap, visibility: CGFloat) {
        guard let container = morph.superview else { return }
        let morphFrame = container.convert(morph.frame, to: window)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipMask.frame = clipRect.offsetBy(dx: -morphFrame.minX, dy: -morphFrame.minY)
        overlapMask.frame = overlapRect.intersection(window.bounds).offsetBy(dx: -morphFrame.minX, dy: -morphFrame.minY)
        overlapMask.opacity = Float(swap.overlapOpacity)
        CATransaction.commit()
        updateUnderlay(morphFrame: morphFrame, clipRect: clipRect, handoff: swap.handoff, visibility: visibility)
        updateBackdropHole(morphFrame: morphFrame)
    }

    /// マスクと一覧の中の写しを外し、最前面の写しをどこでも見せる状態に戻す。
    func tearDown() {
        if morph.layer.mask === morphMask {
            morph.layer.mask = nil
        }
        if backdrop.layer.mask === backdropMask {
            backdrop.layer.mask = nil
        }
        underlay?.image.removeFromSuperview()
    }

    /// 一覧の中の写しを、最前面の写しと同じ位置と見た目にそろえる。
    /// 写しは行からはみ出すため、行をほかの行より手前に描く。`zPosition`を上げるとバーの下のぼかしより手前に出てしまうため、
    /// 同じ`zPosition`の行どうしの並び順で手前に出す。一覧は行を足すときに並び順を変えるため、毎フレーム出し直す。
    /// 最前面の写しを不透明に見せている範囲では、受け渡しの度合いで濃くし、半透明の画像で2枚の写しが重なって濃く見えないようにする。
    /// 重なりの枠では不透明のままにする。そこでは最前面の写しの濃さで入れ替えるため、半透明の画像はその間だけ濃く見える。
    /// 受け渡しの間は2枚を重ねる。不透明な画像は、下の写しを不透明にしないと重ねた結果が薄くなる（上を1-h、下をhの濃さにすると1-h+h²）。
    /// そのため下の写しは受け渡しの度合いが小さいうちに不透明にし、不透明な画像が薄く見えるのを数%に抑える。
    /// 代わりに半透明の画像では、受け渡しの間（既定で開閉の時間の3割）だけ半透明の部分が濃く見える。添付の多くは不透明な写真なので、こちらを受け入れる。
    private func updateUnderlay(morphFrame: CGRect, clipRect: CGRect, handoff: CGFloat, visibility: CGFloat) {
        guard let underlay, let host = underlayHost else { return }
        if let list = host.superview, list.subviews.last !== host {
            list.bringSubviewToFront(host)
        }
        let image = underlay.image
        if image.superview !== host {
            host.addSubview(image)
        } else if host.subviews.last !== image {
            host.bringSubviewToFront(image)
        }
        if image.image !== morph.image {
            image.image = morph.image
        }
        image.frame = host.convert(morphFrame, from: window)
        image.layer.cornerRadius = morph.layer.cornerRadius
        image.alpha = visibility
        underlay.decoration?.alpha = decoration?.alpha ?? 0
        image.backgroundColor = morph.backgroundColor
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
    /// 最前面の写しと入れ替えた部分（バーと重なる部分や、受け渡しの間）だけが暗く見え、境目ができる。
    /// 写しはビューアの画像として下地より手前にあるものなので、どちらの写しを見せていても暗くしない。
    /// 画像の透明な部分は、開いている間も下地の上に描いていたため、そこには下地を残す。
    /// 透明な部分には写しの背景の色（サムネイルの背景）も敷いている。最前面の写しでは背景の色が下地の手前に、一覧の中の写しでは奥にあるため、
    /// 残す下地を背景の色の濃さの分だけ薄くし、下地による暗さを2枚の写しでそろえる。背景の色そのものの明るさには
    /// 下地の濃さと背景の色の濃さの積ほどの差が残るが、背景の色は薄く、下地は開閉しながら濃さが変わるため、受け入れる。
    private func updateBackdropHole(morphFrame: CGRect) {
        guard underlay != nil else { return }
        let hole = backdrop.convert(morphFrame, from: window)
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
        backdropHoleFill.opacity = Float(1 - (morph.backgroundColor?.cgColor.alpha ?? 0))
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
}
