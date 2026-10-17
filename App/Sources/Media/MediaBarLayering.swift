import QuartzCore
import SciaCore
import UIKit

/// ビューアの開閉で、画像の複製を一覧のバーの手前と奥に描き分ける。複製を動かすたびに、同じフレームで`apply`を呼ぶ。
///
/// 最前面の複製（ビューアや閉じる動きの層に置く、バーより手前の複製）は、一覧のバーに隠れない範囲と、指定した重なりの枠にだけ見せる。
/// バーの位置に見せると、バーの手前を通って貫通して見えるため。
/// バーの位置は、一覧の中に置いた同じ複製（`Underlay`）が埋める。一覧の中の複製にはバーの下のぼかしがかかるため、
/// サムネイルの位置でも、バーにかかる部分の見え方がサムネイルとそろう。
/// iOS 26のバーの下のぼかし（scroll edge effect）は、一覧の行（セル）の中身だけを取り込む。コレクションビューの直下に足したビューには
/// かからないため、複製はサムネイルを含む一覧の行の中に置く。
/// バーの`alpha`を下げて複製をバーより手前に見せる方法は使えない。UIKitがナビゲーションバーとタブバーの`alpha`を戻すため、
/// 開いているビューアの上にバーが透けて見えた。
/// バーの下のぼかしはバーの下端より少し下までなだらかにかかり、新着ボタンのように一覧に重なる部品もあるため、
/// サムネイルに近い間は、バーに隠れない範囲でも一覧の中の複製を見せる（受け渡し）。
/// バーと重なる部分は、2枚の複製の濃さを入れ替える。入れ替えの途中は、最前面の複製がバーの部品（タブバーのピルなど）の上に半透明で重なる。
/// 下地の穴をバーに隠れない範囲に限り、入れ替えを暗い下地の奥で済ませる方法も試したが、バーの位置にあたる画面幅いっぱいの帯が
/// 下地の濃さで暗くなり、録画で見比べてこちらを選んだ。
@MainActor
final class MediaBarLayering {
    /// 一覧の中に置き、最前面の複製と同じ位置と見た目で動かす複製。
    struct Underlay {
        let image: UIImageView
        let decoration: UIView?
    }

    private let morph: UIImageView
    /// 最前面の複製に載せた、サムネイルの印の複製。
    private let decoration: UIView?
    private let backdrop: UIView
    /// nilなら、最前面の複製の見せる範囲を絞るだけにする。
    private let underlay: Underlay?
    private let window: UIWindow
    /// サムネイルを含む一覧の、バーに隠れない範囲（ウィンドウ座標）。見つかるまでは画面全体。
    private(set) var visibleRect: CGRect
    /// 一覧の中の複製を載せる、サムネイルを含む一覧の行。
    private weak var underlayHost: UIView?
    /// 最前面の複製のマスク。不透明に見せる範囲と、重なりの枠を重ねる。
    private let morphMask = CALayer()
    private let clipMask = CALayer()
    private let overlapMask = CALayer()
    /// 一覧の中の複製のマスク。最前面の複製を不透明に見せている範囲の外は不透明、内は受け渡しの度合いで濃くする。
    private let underlayMask = CALayer()
    private let underlayOutsideMask = CAShapeLayer()
    private let underlayInsideMask = CALayer()
    /// 下地のマスク。一覧の中の複製を描くとき、複製の枠に穴を開ける。
    private let backdropMask = CALayer()
    private let backdropOutsideMask = CAShapeLayer()
    /// 穴の中で、画像の透明な部分にだけ下地を残す。画像の透明度を反転した画像を、複製と同じ切り抜き方で描く。
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

    /// 一覧の中の複製を描けるか。サムネイルを含む一覧の行が見つかっていなければ描けない。
    var drawsUnderBars: Bool {
        underlay != nil && underlayHost != nil
    }

    /// サムネイルから、一覧の中の複製を載せる行と、一覧のバーに隠れない範囲を探し直す。
    func track(_ tile: any MediaViewerSource) {
        guard let (scrollView, row) = Self.enclosingRow(of: tile) else { return }
        underlayHost = row
        visibleRect = Self.visibleRect(of: scrollView, in: window)
    }

    /// `view`を含む一覧の、バーに隠れない範囲。ウィンドウ座標。一覧に含まれていなければnil。
    static func visibleRect(around view: UIView, in window: UIWindow) -> CGRect? {
        enclosingRow(of: view).map { scrollView, _ in visibleRect(of: scrollView, in: window) }
    }

    private static func visibleRect(of scrollView: UIScrollView, in window: UIWindow) -> CGRect {
        scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: window)
    }

    /// 最前面の複製の今の位置と見た目に合わせて、2枚の複製と下地の穴を描き直す。最前面の複製の`alpha`は呼び出し側で決める。
    /// - Parameters:
    ///   - clipRect: 最前面の複製を不透明に見せる範囲。ウィンドウ座標。
    ///   - overlapRect: `clipRect`のほかに、最前面の複製を`swap.overlapOpacity`の濃さで見せる枠。ウィンドウ座標。
    ///   - visibility: 複製の濃さ。戻り先を見失って薄くするときに1未満にする。
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

    /// マスクと一覧の中の複製を外し、最前面の複製をどこでも見せる状態に戻す。
    func tearDown() {
        if morph.layer.mask === morphMask {
            morph.layer.mask = nil
        }
        if backdrop.layer.mask === backdropMask {
            backdrop.layer.mask = nil
        }
        underlay?.image.removeFromSuperview()
    }

    /// 一覧の中の複製を、最前面の複製と同じ位置と見た目にそろえる。
    /// 複製は行からはみ出すため、行をほかの行より手前に描く。`zPosition`を上げるとバーの下のぼかしより手前に出てしまうため、
    /// 同じ`zPosition`の行どうしの並び順で手前に出す。一覧は行を足すときに並び順を変えるため、毎フレーム出し直す。
    /// 最前面の複製を不透明に見せている範囲では、受け渡しの度合いで濃くし、半透明の画像で2枚の複製が重なって濃く見えないようにする。
    /// 重なりの枠では不透明のままにする。そこでは最前面の複製の濃さで入れ替えるため、半透明の画像はその間だけ濃く見える。
    /// 受け渡しの間は2枚を重ねる。不透明な画像は、下の複製を不透明にしないと重ねた結果が薄くなる（上を1-h、下をhの濃さにすると1-h+h²）。
    /// そのため下の複製は受け渡しの度合いが小さいうちに不透明にし、不透明な画像が薄く見えるのを数%に抑える。
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

    /// 下地のうち複製のある部分に穴を開ける。一覧の中の複製は下地の奥にあるため、穴がないと、
    /// 最前面の複製と入れ替えた部分（バーと重なる部分や、受け渡しの間）だけが暗く見え、境目ができる。
    /// 複製はビューアの画像として下地より手前にあるものなので、どちらの複製を見せていても暗くしない。
    /// 画像の透明な部分は、開いている間も下地の上に描いていたため、そこには下地を残す。
    /// 透明な部分には複製の背景の色（サムネイルの背景）も敷いている。最前面の複製では背景の色が下地の手前に、一覧の中の複製では奥にあるため、
    /// 残す下地を背景の色の濃さの分だけ薄くし、下地による暗さを2枚の複製でそろえる。背景の色そのものの明るさには
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

    /// 受け渡しの度合いのうち、最前面の複製を見せている範囲で一覧の中の複製を不透明にし終えるまでの割合。
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
