import SciaCore
import UIKit

/// 投稿欄の開閉で、カプセルのラベルのアイコンと写真を、書いているときのラベルとサムネイルの列の同じものの位置へ動かす。
///
/// カプセルの行と書いているときの行は、スタックビューの中で入れ替えるので、行の中身を行の外へは動かせない。
/// 両方の端の本物を隠し、バーの上に重ねた複製を、行を入れ替えるのと同じアニメーションの中で動かす。
/// 複製はバーの中に置くので、キーボードに乗ってバーごと動いても、バーの中の位置だけを動かせばよい。
/// カプセルの写真は白いフチが付いて回っているので、複製も大きさ、回転、フチの幅、角の丸みを一緒に移す。
/// カプセルの写真のスタックは、輪郭を合わせた形で影を1つだけ落とす。動いている複製はスタックの形が崩れていくので、写真の複製をまとめて1つの入れ物に入れ、
/// 入れ物の影として、動いている途中の形のまま描く。写真同士の影は、動いている間は描かない。
@MainActor
final class ComposeMorphFlights {
    /// 画面の描き換えと同じ時間。テストでは差し替える。
    var mediaTime: () -> CFTimeInterval = AppDependencies.mediaTime
    enum Key: Hashable {
        case chip
        case attachment(DraftAttachment.ID)
    }

    /// 動かす起点か行き先の本物。
    struct End {
        let view: UIView
        let content: Content
        var cornerRadius: CGFloat = 0
        /// 白いフチの幅。カプセルの写真だけに付く。
        var border: CGFloat = 0
        /// 動かしている間、本物を見えなくする。
        let conceal: (Bool) -> Void
    }

    enum Content {
        case symbol(UIImage?)
        case thumbnail(UIImage?, MediaFocus?)
    }

    private struct Flight {
        let copy: FlightCopy
        /// 隠した本物。動き終えたら、まとめて見せ直す。
        var ends: [End]
        /// 向かっている行き先の形。行が遅れて並べ直されたかを、これと比べて決める。
        var destination: FlightCopy.Geometry?
        /// 動き始める時刻。遅らせて動かす複製は、向かい直すときも、この時刻までは動かし始めない。
        var startTime: CFTimeInterval = 0
    }

    private let container: UIView
    /// 写真の複製をまとめる入れ物。中の複製を合わせた形で、カプセルの写真のスタックと同じ影を落とす。
    /// 動いている間は画面の外で描き直すことになるので、動いていないときは影を消す。
    private lazy var shadowGroup: UIView = {
        let group = UIView(frame: container.bounds)
        group.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        group.isUserInteractionEnabled = false
        PhotoStackShadow.castStack(on: group.layer, opacity: 0)
        container.addSubview(group)
        return group
    }()
    private var flights: [Key: Flight] = [:]
    private var generation = 0
    private static let shadowAnimationKey = "stackShadowOpacity"

    init(container: UIView) {
        self.container = container
    }

    /// 起点の本物を隠し、同じ位置に複製を置く。動かしている途中の複製があれば、そのとき見えている位置から向かい直す。
    /// 行を入れ替える前に呼ぶ。複製は`order`の順に、後ろのものほど手前に重ねる。
    /// `stackShadowOpacity`は、起点で写真のスタックが落としている影の濃さ。動いている途中なら、見えている濃さから向かい直す。
    func takeOff(from sources: [Key: End], stackingOrder order: [Key], stackShadowOpacity: Float) {
        let groupLayer = shadowGroup.layer
        if flights.isEmpty {
            groupLayer.removeAnimation(forKey: Self.shadowAnimationKey)
            groupLayer.shadowOpacity = stackShadowOpacity
        } else {
            let presented = groupLayer.presentation()?.shadowOpacity ?? groupLayer.shadowOpacity
            groupLayer.removeAnimation(forKey: Self.shadowAnimationKey)
            groupLayer.shadowOpacity = presented
        }
        for (key, var flight) in flights {
            flight.copy.freezeAtPresentation()
            if let source = sources[key] {
                conceal(source)
                flight.ends.append(source)
            }
            flights[key] = flight
        }
        for (key, source) in sources where flights[key] == nil {
            let copy = FlightCopy(content: source.content)
            // 写真の複製だけを影の入れ物に入れる。ラベルのアイコンは影を落とさない。
            if case .thumbnail = source.content {
                shadowGroup.addSubview(copy)
            } else {
                container.addSubview(copy)
            }
            copy.apply(geometry(of: source))
            conceal(source)
            flights[key] = Flight(copy: copy, ends: [source])
        }
        container.bringSubviewToFront(shadowGroup)
        for key in order {
            if let copy = flights[key]?.copy {
                copy.superview?.bringSubviewToFront(copy)
            }
        }
    }

    /// 複製を行き先の本物の位置へ動かし、行き先の本物を隠す。行き先のない複製は、薄くして消す。
    /// 行を入れ替えて並べ直したあと、同じアニメーションの中で呼ぶ。返した値を`finish`に渡す。
    /// `delays`にある複製は、その時間だけ遅らせて、`delayedAnimation`が返すアニメーションで動かす。遅らせた複製も、ほかと同じ時刻に着かせる。
    /// 写真のスタックの影は、`duration`の間に`stackShadowOpacity`（カプセルに着くならスタックの影の濃さ、列に着くなら0）へ向かわせる。
    func land(on targets: [Key: End], delays: [Key: TimeInterval], stackShadowOpacity: Float, duration: TimeInterval, delayedAnimation: (TimeInterval, @escaping () -> Void) -> Void) -> Int {
        generation += 1
        // 影の濃さはUIKitのアニメーションで動かないので、Core Animationで動かす。
        let groupLayer = shadowGroup.layer
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = groupLayer.shadowOpacity
        animation.toValue = stackShadowOpacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        groupLayer.shadowOpacity = stackShadowOpacity
        CATransaction.commit()
        groupLayer.add(animation, forKey: Self.shadowAnimationKey)
        for (key, var flight) in flights {
            guard let target = targets[key] else {
                flight.copy.alpha = 0
                continue
            }
            UIView.performWithoutAnimation {
                conceal(target)
                // 行き先のほうが大きな画像を描いていれば差し替え、カプセルの小さな画像を広げてぼやけさせない。
                if case .thumbnail(let image?, let focus) = target.content {
                    flight.copy.replaceThumbnailIfLarger(image, focus: focus)
                }
            }
            let destination = geometry(of: target)
            let delay = delays[key] ?? 0
            flight.ends.append(target)
            flight.destination = destination
            flight.startTime = mediaTime() + delay
            flights[key] = flight
            let copy = flight.copy
            let move = {
                copy.alpha = 1
                copy.apply(destination)
            }
            if delay > 0 {
                delayedAnimation(delay, move)
            } else {
                move()
            }
        }
        return generation
    }

    /// `land`で測った行き先から本物が動いていたら、見えている位置から新しい行き先へ向かい直す。
    /// バーを指で引いてキーボードを閉じたときは、UIKitがキーボードを閉じ終える処理の中から書き終えたことが届き、その場で並べ直しても行が前の形のまま残る。
    /// 行は次の実行ループで並べ直されるので、高さ0のカプセルの行の位置に着いたまま、動き終わりに本物の位置へ飛んでいた。`land`の次の実行ループで呼ぶ。
    /// `animations`には、渡した遅れの時間だけ待ってから、渡した変更を残りの時間で動かすアニメーションを返す。遅らせて動かしている複製は、まだ動き始めていなければ、残りの遅れを守る。
    func retarget(on targets: [Key: End], generation: Int, animations: (TimeInterval, @escaping () -> Void) -> Void) {
        guard generation == self.generation else { return }
        let now = mediaTime()
        var moved: [(FlightCopy, FlightCopy.Geometry, TimeInterval)] = []
        for (key, var flight) in flights {
            guard let target = targets[key], let previous = flight.destination else { continue }
            let destination = geometry(of: target)
            guard destination != previous else { continue }
            if !flight.ends.contains(where: { $0.view === target.view }) {
                conceal(target)
                flight.ends.append(target)
            }
            flight.destination = destination
            flights[key] = flight
            flight.copy.freezeAtPresentation()
            moved.append((flight.copy, destination, max(flight.startTime - now, 0)))
        }
        for (copy, destination, delay) in moved {
            animations(delay) {
                copy.apply(destination)
            }
        }
    }

    /// 動き終えたら、複製を外して本物を見せ直す。あとから別の動きが始まっていれば、その動きに任せてfalseを返す。
    @discardableResult
    func finish(generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        shadowGroup.layer.removeAnimation(forKey: Self.shadowAnimationKey)
        shadowGroup.layer.shadowOpacity = 0
        for flight in flights.values {
            flight.copy.removeFromSuperview()
            for end in flight.ends {
                end.conceal(false)
            }
        }
        flights = [:]
        return true
    }

    private func conceal(_ end: End) {
        UIView.performWithoutAnimation { end.conceal(true) }
    }

    /// 本物の、複製を置く入れ物の中での中心、大きさ、回転。回すのはカプセルの奥の写真だけで、その親は回っていない。
    private func geometry(of end: End) -> FlightCopy.Geometry {
        let view = end.view
        return FlightCopy.Geometry(
            center: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: container),
            size: view.bounds.size,
            rotation: atan2(view.transform.b, view.transform.a),
            cornerRadius: end.cornerRadius,
            border: end.border
        )
    }
}

/// 開閉で動かす複製。カプセルの写真の白いフチは、中の画像を縮めて下地の白を見せて描く。
@MainActor
private final class FlightCopy: UIView {
    struct Geometry: Equatable {
        let center: CGPoint
        let size: CGSize
        let rotation: CGFloat
        let cornerRadius: CGFloat
        let border: CGFloat
    }

    private let inner: UIView
    private var border: CGFloat = 0

    init(content: ComposeMorphFlights.Content) {
        switch content {
        case .symbol(let image):
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.tintColor = .tintColor
            inner = imageView
        case .thumbnail(let image, let focus):
            let imageView = FocusCroppedImageView()
            imageView.image = image
            imageView.focus = focus
            imageView.backgroundColor = .secondarySystemFill
            inner = imageView
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        inner.clipsToBounds = true
        inner.layer.cornerCurve = .continuous
        // カプセルの写真の回転へ向かうので、縁がギザギザにならないようにする。
        layer.allowsEdgeAntialiasing = true
        inner.layer.allowsEdgeAntialiasing = true
        layer.cornerCurve = .continuous
        if case .thumbnail = content {
            backgroundColor = PhotoPaper.color
        }
        addSubview(inner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// アニメーションの中で呼ぶと、外枠、中の画像、角の丸みを一緒に動かす。
    func apply(_ geometry: Geometry) {
        border = geometry.border
        bounds = CGRect(origin: .zero, size: geometry.size)
        center = geometry.center
        transform = CGAffineTransform(rotationAngle: geometry.rotation)
        layer.cornerRadius = geometry.cornerRadius
        inner.layer.cornerRadius = max(geometry.cornerRadius - geometry.border / 2, 0)
        setNeedsLayout()
        layoutIfNeeded()
        inner.setNeedsLayout()
        inner.layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        inner.frame = bounds.insetBy(dx: border, dy: border)
    }

    /// 動いている途中の見えている形で止め、そこから次の行き先へ向かい直せるようにする。
    func freezeAtPresentation() {
        let presented = layer.presentation()
        let innerPresented = inner.layer.presentation()
        let size = presented?.bounds.size ?? bounds.size
        let innerSize = innerPresented?.bounds.size ?? inner.bounds.size
        let position = presented?.position ?? center
        let presentedTransform = presented.map { CATransform3DGetAffineTransform($0.transform) } ?? transform
        let radius = presented?.cornerRadius ?? layer.cornerRadius
        let innerRadius = innerPresented?.cornerRadius ?? inner.layer.cornerRadius
        let opacity = presented.map { CGFloat($0.opacity) } ?? alpha
        // 中の画像（`FocusCroppedImageView`の中の画像）も前の行き先へ動き続けるので、中まですべての動きを止め、今の大きさで並べ直す。
        Self.removeAllAnimations(in: layer)
        border = max((size.width - innerSize.width) / 2, 0)
        bounds = CGRect(origin: .zero, size: size)
        center = position
        transform = presentedTransform
        layer.cornerRadius = radius
        inner.layer.cornerRadius = innerRadius
        alpha = opacity
        setNeedsLayout()
        layoutIfNeeded()
        inner.setNeedsLayout()
        inner.layoutIfNeeded()
    }

    private static func removeAllAnimations(in layer: CALayer) {
        layer.removeAllAnimations()
        for sublayer in layer.sublayers ?? [] {
            removeAllAnimations(in: sublayer)
        }
    }

    func replaceThumbnailIfLarger(_ image: UIImage, focus: MediaFocus?) {
        guard let imageView = inner as? FocusCroppedImageView, image.size.width > (imageView.image?.size.width ?? 0) else { return }
        imageView.image = image
        imageView.focus = focus
    }
}
