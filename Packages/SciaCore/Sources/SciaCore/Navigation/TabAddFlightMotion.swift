public import CoreGraphics

/// 「タブに追加」で、足した項目のアイコンを右上の「タブ」ボタンから切り替えタブのボタンへ飛ばす動きの値と、飛ぶ間の計算。決まりはdocs/tabs.mdの「ユーザーのハッシュタグ」にある。
///
/// アイコンは2枚重ねのビューで動かす。内側のビューが浮かび上がりのスプリング（大きさと不透明度）を、外側のビューが飛ぶ間の位置と、大きさと不透明度に掛ける倍率を持つ。
/// 見える大きさと不透明度は2つの掛け算になり、飛び始めてもスプリングは止まらずに続くので、倍率を1から始めれば値も速さも途切れない。
/// 値は、作者がブラウザで再生しながら決めたもので、固定にしている。
public enum TabAddFlightMotion {
    /// アイコンの大きさ（pt）。
    public static let iconSide: CGFloat = 34

    /// 浮かび上がりのスプリング。大きさは`popScaleFrom`倍から`popScalePeak`倍へ、不透明度は`popOpacityFrom`から1へ。
    public static let popScaleFrom: CGFloat = 0.2
    public static let popScalePeak: CGFloat = 1.25
    public static let popScaleSpring = SpringCurve(duration: 0.27, bounce: 0.5)
    public static let popOpacityFrom: CGFloat = 0
    public static let popOpacitySpring = SpringCurve(duration: 0.35, bounce: 0)

    /// 浮かび上がり始めてから飛び始めるまでの時間（秒）と、飛ぶ時間（秒）。
    public static let departDelay: Double = 0.22
    public static let flightDuration: Double = 0.55

    /// 軌道の3次ベジェの取っ手。1つ目は飛び立つ点から、2つ目は着く点からのずれ（pt）。
    public static let startHandle = CGVector(dx: -117, dy: 31)
    public static let endHandle = CGVector(dx: -104, dy: -394)
    /// 軌道の上の進み具合を、時間に対してどう進めるか。CSSや`CAMediaTimingFunction`と同じcubic-bezier。
    public static let positionTiming = UnitBezier(x1: 0.55, y1: 0, x2: 0.85, y2: 0.6)
    /// 飛ぶ間の進み具合（0〜1）に対する、浮かび上がった大きさと不透明度に掛ける倍率。
    public static let scaleMultiplier = KeyframeCurve(points: [(0, 1), (0.25, 0.977), (0.508, 0.957), (0.724, 0.957), (0.892, 0.843), (1, 0.28)], smooth: true)
    public static let opacityMultiplier = KeyframeCurve(points: [(0, 1), (0.9, 1), (1, 0)], smooth: false)

    /// 着いたとき、切り替えタブのボタンの上に広げる輪。大きさは`ringScaleFrom`倍から`ringScaleTo`倍へ、不透明度は`ringOpacityFrom`から0へ。
    public static let ringSpring = SpringCurve(duration: 0.7, bounce: 0)
    public static let ringScaleFrom: CGFloat = 0.85
    public static let ringScaleTo: CGFloat = 1.45
    public static let ringOpacityFrom: CGFloat = 0.65

    /// 飛ぶ間のある時点の、外側のビューの位置と倍率。
    public struct Sample: Equatable, Sendable {
        public let position: CGPoint
        public let scale: CGFloat
        public let opacity: CGFloat
    }

    /// 飛ぶ間の進み具合`progress`（0〜1）での、外側のビューの位置と倍率。
    public static func sample(at progress: Double, from start: CGPoint, to end: CGPoint) -> Sample {
        let t = positionTiming.value(at: progress)
        let handle1 = CGPoint(x: start.x + startHandle.dx, y: start.y + startHandle.dy)
        let handle2 = CGPoint(x: end.x + endHandle.dx, y: end.y + endHandle.dy)
        let position = CGPoint(
            x: UnitBezier.cubic(start.x, handle1.x, handle2.x, end.x, CGFloat(t)),
            y: UnitBezier.cubic(start.y, handle1.y, handle2.y, end.y, CGFloat(t))
        )
        return Sample(position: position, scale: CGFloat(scaleMultiplier.value(at: progress)), opacity: CGFloat(min(1, max(0, opacityMultiplier.value(at: progress)))))
    }

    /// 飛ぶ間を`count`等分した、両端を含む`count + 1`個の時点の値。キーフレームを直線でつなぐと、細かく刻むほど上の式どおりに動く。
    /// 軌道を`CAKeyframeAnimation`の`path`で渡さないのは、Core Animationが曲線の上をどう進めるかが式と一致する保証がないため。
    public static func samples(count: Int, from start: CGPoint, to end: CGPoint) -> [Sample] {
        precondition(count > 0, "刻みの数は1以上にします")
        return (0...count).map { sample(at: Double($0) / Double(count), from: start, to: end) }
    }
}

/// CSSの`cubic-bezier()`や`CAMediaTimingFunction(controlPoints:)`と同じ、(0, 0)から(1, 1)への3次ベジェのイージング。
public struct UnitBezier: Sendable, Equatable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        precondition((0...1).contains(x1) && (0...1).contains(x2), "取っ手の横の位置は0から1にします")
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// 時間の割合`x`での進み具合。横の位置がxになる曲線のパラメーターを二分法で求め、その縦の位置を返す。
    public func value(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<40 {
            let current = Self.cubic(0, x1, x2, 1, t)
            if abs(current - x) < 1e-7 { break }
            if current < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return Self.cubic(0, y1, y2, 1, t)
    }

    static func cubic<T: BinaryFloatingPoint>(_ a: T, _ b: T, _ c: T, _ d: T, _ t: T) -> T {
        let u = 1 - t
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
    }
}

/// 時点と値の点を並べた曲線。点の間を直線か、なめらかな曲線（各点の傾きを前後の点から決めるエルミート曲線）でつなぐ。
public struct KeyframeCurve: Sendable {
    public let points: [(time: Double, value: Double)]
    public let smooth: Bool

    public init(points: [(time: Double, value: Double)], smooth: Bool) {
        precondition(points.count >= 2, "点は2つ以上にします")
        precondition(zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time }, "点の時点は前の点より後にします")
        self.points = points
        self.smooth = smooth
    }

    public func value(at time: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        guard time > first.time else { return first.value }
        guard time < last.time else { return last.value }
        var index = 0
        while index < points.count - 2 && time > points[index + 1].time { index += 1 }
        let (t0, v0) = points[index], (t1, v1) = points[index + 1]
        let span = t1 - t0
        let u = (time - t0) / span
        guard smooth else { return v0 + (v1 - v0) * u }
        let slope0 = index == 0 ? slope(0, 1) : slope(index - 1, index + 1)
        let slope1 = index + 1 == points.count - 1 ? slope(index, index + 1) : slope(index, index + 2)
        let u2 = u * u, u3 = u2 * u
        return (2 * u3 - 3 * u2 + 1) * v0 + (u3 - 2 * u2 + u) * span * slope0 + (-2 * u3 + 3 * u2) * v1 + (u3 - u2) * span * slope1
    }

    private func slope(_ a: Int, _ b: Int) -> Double {
        (points[b].value - points[a].value) / (points[b].time - points[a].time)
    }
}
