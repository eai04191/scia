import UIKit

/// ビューアの開閉で動かす画像の複製の、すぐ後ろに置く影。複製は中の画像を角で切り抜いているので、自分には影を描けない。
/// 一覧で重ねた写真のように影を落とす起点とのあいだでは、起点の近くで起点と同じ影にし、離れるにつれて薄くする。
/// 影のない複製が着いたところで、本物の影が一度に現れて見えないようにするため。
///
/// 影は複製の形の外側にだけ描く。形の内側にも敷くと、閉じる最後に複製を薄くして一覧の中の複製へ受け渡す間、
/// 下の複製が影越しに暗く見え、着いたところで明るさが戻って見えるため。
/// 自分のマスクは、バーの奥に描き分けるときの切り抜き（`MediaBarLayering`）に空けておき、内側を抜くのは影を描く層のマスクで行う。
@MainActor
final class MorphShadowView: UIView {
    private let caster = CALayer()
    private let cutout = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        PhotoStackShadow.castStack(on: caster, opacity: 0)
        cutout.fillRule = .evenOdd
        cutout.fillColor = UIColor.black.cgColor
        caster.mask = cutout
        layer.addSublayer(caster)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 影の濃さ。0なら描かない。
    var opacity: Float {
        get { caster.shadowOpacity }
        set {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            caster.shadowOpacity = newValue
            CATransaction.commit()
        }
    }

    /// 複製のすぐ後ろに、同じ位置、大きさ、角度、角の丸みで置く。複製を別の層へ移したときも、同じ層へ付いていく。
    /// バーの奥に描き分けるときは、切り抜き（`MediaBarLayering`）を影の座標で計算するので、切り抜きを描き直す前に呼ぶ。
    /// - Parameter alpha: 影全体の濃さ。複製の濃さは写さない。複製はバーの奥に描き分ける間や、閉じる最後に一覧の中の複製へ受け渡す間に
    ///   薄くするが、影はそのあいだも残すため。
    func follow(_ morph: UIView, alpha: CGFloat) {
        attach(below: morph)
        place(bounds: morph.bounds, center: morph.center, transform: morph.transform, cornerRadius: morph.layer.cornerRadius, alpha: alpha)
    }

    /// UIKitのアニメーションで動いている複製の、いま見えている位置に置く。影の形（`shadowPath`）はUIKitのアニメーションでは動かないため、
    /// 動いている間は毎フレーム呼ぶ。
    func followPresentation(of morph: UIView, alpha: CGFloat) {
        attach(below: morph)
        let shown = morph.layer.presentation() ?? morph.layer
        place(
            bounds: shown.bounds,
            center: shown.position,
            transform: CATransform3DGetAffineTransform(shown.transform),
            cornerRadius: shown.cornerRadius,
            alpha: alpha
        )
    }

    private func attach(below morph: UIView) {
        if let container = morph.superview, superview !== container || container.subviews.firstIndex(of: self) != container.subviews.firstIndex(of: morph).map({ $0 - 1 }) {
            container.insertSubview(self, belowSubview: morph)
        }
        isHidden = morph.isHidden
    }

    private func place(bounds: CGRect, center: CGPoint, transform: CGAffineTransform, cornerRadius: CGFloat, alpha: CGFloat) {
        self.alpha = alpha
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.transform = .identity
        self.bounds = bounds
        self.center = center
        self.transform = transform
        let shape = UIBezierPath(roundedRect: self.bounds, cornerRadius: cornerRadius)
        caster.frame = self.bounds
        caster.shadowPath = shape.cgPath
        // 影の広がりより十分外まで残し、形の内側だけを抜く。
        let outside = UIBezierPath(rect: self.bounds.insetBy(dx: -40, dy: -40))
        outside.append(shape)
        cutout.frame = self.bounds
        cutout.path = outside.cgPath
        CATransaction.commit()
    }
}
