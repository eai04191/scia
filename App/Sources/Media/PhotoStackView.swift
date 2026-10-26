import SciaCore
import UIKit

/// 添付ファイルを、白いフチを付けた紙焼きの写真に見立てて、1枚目を手前にして重ねる。投稿欄のカプセルと、一覧で本文の右に出す添付ファイルで使う。
/// アイコンのように見えないよう写真に見立て、2枚目より後ろは1枚目の下に重ねる。重ねる枚数は使う側が決め、それより後ろはいちばん奥の写真の下に隠れているものとし、枚数のバッジは付けない。
/// 回す角度とずらす量、影の濃さは、使う側が決めて渡す。
///
/// 影は、写真のスタックが下の面に落とす影と、上の写真が下の写真に落とす影の2つに分ける。写真ごとに影を付けると、
/// 重なったところで影が二重に濃くなり、写真の上に落ちる影も下の面に落ちる影と同じ広さになるため。
@MainActor
class PhotoStackView: UIView {
    /// 写真ごとの回す角度（ラジアン）。先頭が1枚目。
    private var rotations: [CGFloat]
    /// 写真ごとの、1枚目の中心からずらす量。先頭（1枚目）は0。
    private var offsets: [CGPoint]
    /// 写真同士の影の濃さ。
    private var betweenShadowOpacity: Float = 0

    /// 写真の一辺（フチを含む）。
    var photoSide: CGFloat = 26 {
        didSet {
            guard photoSide != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// 写真のスタックが下の面に落とす影。重ねた写真の輪郭を合わせた形で、影を1つだけ落とす。
    private let stackShadow = UIView()
    /// 重ねる写真。先頭が手前の1枚目で、後ろほど下に重ねる。添付が足りない分は、使う側が隠す。
    let photos: [StackedPhotoView]
    /// 手前の1枚。1枚目の添付。
    var front: StackedPhotoView { photos[0] }
    /// 奥の1枚。2枚目の添付。2枚以上のときだけ出す。
    var back: StackedPhotoView { photos[1] }
    /// 2枚目の下の1枚。3枚目の添付。3枚以上のときだけ出す。
    var third: StackedPhotoView { photos[2] }

    /// - Parameter photoCount: 重ねる写真の数。3以上。
    init(store: MediaImageStore, photoCount: Int = 3) {
        precondition(photoCount >= 3, "写真のスタックは3枚以上を重ねる")
        photos = (0..<photoCount).map { _ in StackedPhotoView(store: store) }
        rotations = Array(repeating: 0, count: photoCount)
        offsets = Array(repeating: .zero, count: photoCount)
        super.init(frame: .zero)
        stackShadow.isUserInteractionEnabled = false
        addSubview(stackShadow)
        for photo in photos.reversed() {
            addSubview(photo)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 写真ごとの置き方。先頭が1枚目で、ずらす量はptで渡す。1枚目のずらす量は使わない。足りない写真は、回さずずらさずに置く。
    func setPlacements(_ placements: [PhotoStackPlacement]) {
        let degree = CGFloat.pi / 180
        for (index, photo) in photos.enumerated() {
            let placement = index < placements.count ? placements[index] : PhotoStackPlacement(rotation: 0)
            rotations[index] = placement.rotation * degree
            offsets[index] = index == 0 ? .zero : CGPoint(x: placement.offsetX, y: placement.offsetY)
            photo.transform = CGAffineTransform(rotationAngle: rotations[index])
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// - Parameters:
    ///   - stack: 写真のスタックが下の面に落とす影の濃さ。
    ///   - between: 上の写真が下の写真に落とす影の濃さ。
    func setShadowOpacities(stack: Float, between: Float) {
        betweenShadowOpacity = between
        PhotoStackShadow.castStack(on: stackShadow.layer, opacity: stack)
        setNeedsLayout()
    }

    /// 写真を隠している間は、スタックの影も隠す。開閉で動かす複製がまとめて影を落とすため。
    func setStackShadowConcealed(_ concealed: Bool) {
        stackShadow.alpha = concealed ? 0 : 1
    }

    /// 写真同士の影を、薄い状態から浮かび上がらせる。開閉で写真が着いたあとに呼ぶ。動いている間の複製は、写真同士の影を落とさないため。
    func revealBetweenShadows(duration: TimeInterval) {
        for photo in photos {
            photo.revealBetweenShadow(duration: duration)
        }
    }

    /// 見えている写真の、1枚目の中心から見た左右の端。回した写真の角も含める。スタックの幅はこの間にし、1枚目を左端からこの分だけ右に置く。
    private var horizontalExtent: (minX: CGFloat, maxX: CGFloat) {
        let half = photoSide / 2
        let placements = photos.indices
            .filter { $0 == 0 || !photos[$0].isHidden }
            .map { (offset: offsets[$0].x, rotation: rotations[$0]) }
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
        for (photo, offset) in zip(photos, offsets) {
            photo.bounds.size = size
            photo.center = CGPoint(x: frontCenter.x + offset.x, y: frontCenter.y + offset.y)
        }
        layoutShadows()
    }

    /// スタックの影は見えている写真の輪郭を合わせた形で、写真同士の影は、下の写真の中に、それより上の写真の輪郭で落とす。
    private func layoutShadows() {
        // ビューアのために隠している写真は、影も落とさない。
        let stacked = photos.filter { !$0.isHidden && !$0.isConcealed }
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
        let path = UIBezierPath(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), cornerRadius: StackedPhotoView.cornerRadius)
        path.apply(photo.transform)
        path.apply(CGAffineTransform(translationX: photo.center.x, y: photo.center.y))
        return path
    }
}

/// 重ねた写真の影の形。写真は薄いので、写真同士の影は、スタックが下の面に落とす影より近く、ぼかしも小さい。
/// 影の広がりは写真が下の面から浮いている高さで決まり、写真の大きさでは変わらないので、どの大きさの写真でも同じにする。
enum PhotoStackShadow {
    /// 写真のスタックが下の面に落とす影。
    static func castStack(on layer: CALayer, opacity: Float) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 0.5)
    }

    /// 上の写真が下の写真に落とす影。
    static func castBetween(on layer: CALayer, opacity: Float) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = 0.75
        layer.shadowOffset = CGSize(width: 0, height: 0.25)
    }
}

/// 白いフチの付いた紙焼きの写真。自分では影を落とさず、上に重ねた写真の影を、自分の中にだけ描く。
@MainActor
final class StackedPhotoView: UIView {
    /// フチの太さと角の丸み。紙焼きの写真は、大きく焼いてもフチや角が大きさに比例して太くならないので、写真の大きさによらず同じにする。
    static let border: CGFloat = 2
    static let cornerRadius: CGFloat = 3

    let tile: MediaTileView
    /// 上に重ねた写真の影を、この写真の外にはみ出させずに描く枠。
    private let betweenShadowClip = UIView()
    private let betweenShadow = CALayer()
    private let failureMark = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))

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
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        tile.isUserInteractionEnabled = false
        tile.isAccessibilityElement = false
        // 小さな枠では、ALTやGIFのバッジは読めないため出さない。手前の写真に出すかは、使う側が決める。
        tile.hidesBadge = true
        tile.layer.cornerRadius = Self.cornerRadius - Self.border / 2
        tile.paperBorder = (Self.border, Self.cornerRadius)
        // 回して置くので、縁がギザギザにならないよう、紙と中の画像の縁をなめらかに描く。
        layer.allowsEdgeAntialiasing = true
        tile.layer.allowsEdgeAntialiasing = true
        addSubview(tile)
        betweenShadowClip.isUserInteractionEnabled = false
        betweenShadowClip.clipsToBounds = true
        betweenShadowClip.layer.cornerRadius = Self.cornerRadius
        betweenShadowClip.layer.cornerCurve = .continuous
        betweenShadowClip.layer.addSublayer(betweenShadow)
        addSubview(betweenShadowClip)
        // 感嘆符を白、円を赤で描き、どんなサムネイルの上でも見分けられるようにする。列のエラーのアイコンと同じ。
        failureMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12).applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        failureMark.isHidden = true
        addSubview(failureMark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 上に重ねた写真の輪郭（この写真の中の位置）で、影を落とす。上に写真がなければnil。
    func setBetweenShadow(outline: CGPath?, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        betweenShadow.shadowPath = outline
        PhotoStackShadow.castBetween(on: betweenShadow, opacity: outline == nil ? 0 : opacity)
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
        tile.frame = bounds.insetBy(dx: Self.border, dy: Self.border)
        betweenShadowClip.frame = bounds
        betweenShadow.frame = bounds
        let mark = failureMark.intrinsicContentSize
        failureMark.frame = CGRect(x: bounds.maxX - mark.width / 2 - 1, y: bounds.maxY - mark.height / 2 - 1, width: mark.width, height: mark.height)
    }
}
