import SciaCore
import UIKit

/// 添付ファイルを、白いフチを付けた紙焼きの写真に見立てて、1枚目を手前にして3枚目までを重ねる。投稿欄のカプセルと、一覧で本文の右に出す添付ファイルで使う。
/// アイコンのように見えないよう写真に見立て、2枚目は1枚目の下に重ねる。手で置いた写真らしく、どれも真っすぐにはせず回す。
/// 3枚目は、2枚だけが置かれて見える不自然さをなくすためのもので、いちばん下に置き、2枚目と逆の側からのぞかせる。
/// 4枚目より後ろは3枚目の下に隠れているものとし、枚数のバッジは付けない。
/// 回す角度とずらす量、影の濃さは、使う側が決めて渡す。
///
/// 影は、写真のスタックが下の面に落とす影と、上の写真が下の写真に落とす影の2つに分ける。写真ごとに影を付けると、
/// 重なったところで影が二重に濃くなり、写真の上に落ちる影も下の面に落ちる影と同じ広さになるため。
@MainActor
class PhotoStackView: UIView {
    /// 手前の1枚を回す角度（ラジアン）。
    private var frontRotation: CGFloat = 0
    /// 奥の1枚を回す角度（ラジアン）。
    private var backRotation: CGFloat = 0
    /// 奥の1枚の中心を、手前の1枚の中心からずらす量。
    private var backOffset = CGPoint.zero
    /// 3枚目を回す角度（ラジアン）。
    private var thirdRotation: CGFloat = 0
    /// 3枚目の中心を、手前の1枚の中心からずらす量。
    private var thirdOffset = CGPoint.zero
    /// 写真同士の影の濃さ。
    private var betweenShadowOpacity: Float = 0
    private var stackShadowOpacity: Float = 0

    /// 写真の一辺（フチを含む）。
    var photoSide: CGFloat = 26 {
        didSet {
            guard photoSide != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// フチの太さ、角の丸み、影の広がりの倍率。投稿欄のカプセルの写真を1とし、大きな写真でも同じ形にする。
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            for photo in [front, back, third] {
                photo.scale = scale
            }
            PhotoStackShadow.castStack(on: stackShadow.layer, opacity: stackShadowOpacity, scale: scale)
            setNeedsLayout()
        }
    }

    /// 写真のスタックが下の面に落とす影。重ねた写真の輪郭を合わせた形で、影を1つだけ落とす。
    private let stackShadow = UIView()
    /// 手前の1枚。1枚目の添付。
    let front: StackedPhotoView
    /// 奥の1枚。2枚目の添付。2枚以上のときだけ出す。
    let back: StackedPhotoView
    /// 2枚目の下の1枚。3枚目の添付。3枚以上のときだけ出す。
    let third: StackedPhotoView

    init(store: MediaImageStore) {
        front = StackedPhotoView(store: store)
        back = StackedPhotoView(store: store)
        third = StackedPhotoView(store: store)
        super.init(frame: .zero)
        stackShadow.isUserInteractionEnabled = false
        for view in [stackShadow, third, back, front] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 1枚目、2枚目、3枚目の置き方。ずらす量はptで渡す。3つ揃っていなければ何もしない。
    func setPlacements(_ placements: [PhotoStackPlacement]) {
        guard placements.count == 3 else { return }
        let degree = CGFloat.pi / 180
        frontRotation = placements[0].rotation * degree
        backRotation = placements[1].rotation * degree
        backOffset = CGPoint(x: placements[1].offsetX, y: placements[1].offsetY)
        thirdRotation = placements[2].rotation * degree
        thirdOffset = CGPoint(x: placements[2].offsetX, y: placements[2].offsetY)
        front.transform = CGAffineTransform(rotationAngle: frontRotation)
        back.transform = CGAffineTransform(rotationAngle: backRotation)
        third.transform = CGAffineTransform(rotationAngle: thirdRotation)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// - Parameters:
    ///   - stack: 写真のスタックが下の面に落とす影の濃さ。
    ///   - between: 上の写真が下の写真に落とす影の濃さ。
    func setShadowOpacities(stack: Float, between: Float) {
        stackShadowOpacity = stack
        betweenShadowOpacity = between
        PhotoStackShadow.castStack(on: stackShadow.layer, opacity: stack, scale: scale)
        setNeedsLayout()
    }

    /// 写真を隠している間は、スタックの影も隠す。開閉で動かす複製がまとめて影を落とすため。
    func setStackShadowConcealed(_ concealed: Bool) {
        stackShadow.alpha = concealed ? 0 : 1
    }

    /// 写真同士の影を、薄い状態から浮かび上がらせる。開閉で写真が着いたあとに呼ぶ。動いている間の複製は、写真同士の影を落とさないため。
    func revealBetweenShadows(duration: TimeInterval) {
        for photo in [front, back, third] {
            photo.revealBetweenShadow(duration: duration)
        }
    }

    /// 見えている写真の、1枚目の中心から見た左右の端。回した写真の角も含める。スタックの幅はこの間にし、1枚目を左端からこの分だけ右に置く。
    private var horizontalExtent: (minX: CGFloat, maxX: CGFloat) {
        let half = photoSide / 2
        var placements = [(offset: CGFloat(0), rotation: frontRotation)]
        if !back.isHidden {
            placements.append((backOffset.x, backRotation))
        }
        if !third.isHidden {
            placements.append((thirdOffset.x, thirdRotation))
        }
        let extents = placements.map { placement in
            let reach = half * (abs(cos(placement.rotation)) + abs(sin(placement.rotation)))
            return (placement.offset - reach, placement.offset + reach)
        }
        return (extents.map(\.0).min() ?? -half, extents.map(\.1).max() ?? half)
    }

    /// 回した写真が上下にはみ出す分は、行の高さに収まらないので幅だけ取り、上下ははみ出させる。
    override var intrinsicContentSize: CGSize {
        let extent = horizontalExtent
        return CGSize(width: extent.maxX - extent.minX, height: photoSide)
    }

    /// 1枚目の写真の中心。左右は回した写真の角までを幅に収め、上下は真ん中に置く。
    func frontCenter() -> CGPoint {
        CGPoint(x: -horizontalExtent.minX, y: bounds.midY)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: photoSide, height: photoSide)
        let frontCenter = frontCenter()
        front.bounds.size = size
        front.center = frontCenter
        back.bounds.size = size
        back.center = CGPoint(x: frontCenter.x + backOffset.x, y: frontCenter.y + backOffset.y)
        third.bounds.size = size
        third.center = CGPoint(x: frontCenter.x + thirdOffset.x, y: frontCenter.y + thirdOffset.y)
        layoutShadows()
    }

    /// スタックの影は見えている写真の輪郭を合わせた形で、写真同士の影は、下の写真の中に、それより上の写真の輪郭で落とす。
    private func layoutShadows() {
        // ビューアのために隠している写真は、影も落とさない。
        let stacked = [front, back, third].filter { !$0.isHidden && !$0.isConcealed }
        stackShadow.frame = bounds
        let union = UIBezierPath()
        for photo in stacked {
            union.append(outline(of: photo))
        }
        stackShadow.layer.shadowPath = union.cgPath
        for (index, photo) in stacked.enumerated() {
            let above = stacked.prefix(index)
            guard !above.isEmpty else {
                photo.setBetweenShadow(outline: nil, opacity: 0)
                continue
            }
            let outline = UIBezierPath()
            for upper in above {
                outline.append(self.outline(of: upper))
            }
            // スタックの中の位置から、下の写真の中の位置へ移す。
            let toPhoto = CGAffineTransform(translationX: -photo.center.x, y: -photo.center.y)
                .concatenating(photo.transform.inverted())
                .concatenating(CGAffineTransform(translationX: photo.bounds.width / 2, y: photo.bounds.height / 2))
            outline.apply(toPhoto)
            photo.setBetweenShadow(outline: outline.cgPath, opacity: betweenShadowOpacity)
        }
    }

    /// 写真の輪郭を、スタックの中の位置で返す。
    private func outline(of photo: StackedPhotoView) -> UIBezierPath {
        let size = photo.bounds.size
        let path = UIBezierPath(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), cornerRadius: photo.photoCornerRadius)
        path.apply(photo.transform)
        path.apply(CGAffineTransform(translationX: photo.center.x, y: photo.center.y))
        return path
    }
}

/// 重ねた写真の影の形。写真は薄いので、写真同士の影は、スタックが下の面に落とす影より近く、ぼかしも小さい。
/// 広がりは、投稿欄のカプセルの写真を1とした倍率`scale`で大きくする。
enum PhotoStackShadow {
    /// 写真のスタックが下の面に落とす影。
    static func castStack(on layer: CALayer, opacity: Float, scale: CGFloat = 1) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = 1.5 * scale
        layer.shadowOffset = CGSize(width: 0, height: 0.5 * scale)
    }

    /// 上の写真が下の写真に落とす影。
    static func castBetween(on layer: CALayer, opacity: Float, scale: CGFloat = 1) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = 0.75 * scale
        layer.shadowOffset = CGSize(width: 0, height: 0.25 * scale)
    }
}

/// 白いフチの付いた紙焼きの写真。自分では影を落とさず、上に重ねた写真の影を、自分の中にだけ描く。
@MainActor
final class StackedPhotoView: UIView {
    /// 投稿欄のカプセルの写真の、フチの太さと角の丸み。ほかの大きさでは`scale`を掛ける。
    static let border: CGFloat = 2
    static let cornerRadius: CGFloat = 3

    let tile: MediaTileView
    /// 上に重ねた写真の影を、この写真の外にはみ出させずに描く枠。
    private let betweenShadowClip = UIView()
    private let betweenShadow = CALayer()
    private let failureMark = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    private var betweenShadowOpacity: Float = 0

    /// フチの太さ、角の丸み、写真同士の影の広がりの倍率。
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            applyCornerRadius()
            setNeedsLayout()
        }
    }

    var photoBorder: CGFloat { Self.border * scale }
    var photoCornerRadius: CGFloat { Self.cornerRadius * scale }

    /// フチごと隠している。ビューアが一覧の写真とのあいだで画像を動かしている間に使う。
    /// 透明にすると触れても反応しなくなるため、サムネイルと同じく空のマスクで隠す。
    var isConcealed = false {
        didSet {
            guard isConcealed != oldValue else { return }
            layer.mask = isConcealed ? CALayer() : nil
            superview?.setNeedsLayout()
        }
    }

    /// 送れなかった添付があることを、右下の角にアイコンで出す。
    var showsFailure = false {
        didSet { failureMark.isHidden = !showsFailure }
    }

    init(store: MediaImageStore) {
        tile = MediaTileView(store: store)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .white
        layer.cornerCurve = .continuous
        tile.isUserInteractionEnabled = false
        tile.isAccessibilityElement = false
        // 小さな枠では、ALTやGIFのバッジは読めないため出さない。手前の写真に出すかは、使う側が決める。
        tile.hidesBadge = true
        // 回して置くので、縁がギザギザにならないよう、紙と中の画像の縁をなめらかに描く。
        layer.allowsEdgeAntialiasing = true
        tile.layer.allowsEdgeAntialiasing = true
        addSubview(tile)
        betweenShadowClip.isUserInteractionEnabled = false
        betweenShadowClip.clipsToBounds = true
        betweenShadowClip.layer.cornerCurve = .continuous
        betweenShadowClip.layer.addSublayer(betweenShadow)
        addSubview(betweenShadowClip)
        applyCornerRadius()
        // 感嘆符を白、円を赤で描き、どんなサムネイルの上でも見分けられるようにする。列のエラーのアイコンと同じ。
        failureMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12).applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        failureMark.isHidden = true
        addSubview(failureMark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyCornerRadius() {
        layer.cornerRadius = photoCornerRadius
        tile.layer.cornerRadius = photoCornerRadius - photoBorder / 2
        betweenShadowClip.layer.cornerRadius = photoCornerRadius
        PhotoStackShadow.castBetween(on: betweenShadow, opacity: betweenShadow.shadowPath == nil ? 0 : betweenShadowOpacity, scale: scale)
    }

    /// 上に重ねた写真の輪郭（この写真の中の位置）で、影を落とす。上に写真がなければnil。
    func setBetweenShadow(outline: CGPath?, opacity: Float) {
        betweenShadowOpacity = opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        betweenShadow.shadowPath = outline
        PhotoStackShadow.castBetween(on: betweenShadow, opacity: outline == nil ? 0 : opacity, scale: scale)
        CATransaction.commit()
    }

    func revealBetweenShadow(duration: TimeInterval) {
        UIView.performWithoutAnimation { betweenShadowClip.alpha = 0 }
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.betweenShadowClip.alpha = 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tile.frame = bounds.insetBy(dx: photoBorder, dy: photoBorder)
        betweenShadowClip.frame = bounds
        betweenShadow.frame = bounds
        let mark = failureMark.intrinsicContentSize
        failureMark.frame = CGRect(x: bounds.maxX - mark.width / 2 - 1, y: bounds.maxY - mark.height / 2 - 1, width: mark.width, height: mark.height)
    }
}
