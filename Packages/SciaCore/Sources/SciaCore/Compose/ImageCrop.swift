public import CoreGraphics

/// 送る前に画像を切り抜く範囲。元のファイルは残し、送るファイルを作るときに当てる。決まりはdocs/media-attachment.mdの「トリミング」にある。
public struct ImageCrop: Sendable, Equatable {
    /// 時計回りに90度回す回数。0から3。
    public let quarterTurns: Int
    /// 回したあとの画像のうち、残す範囲。左上を0、右下を1にした割合。
    public let rect: CGRect

    /// 回したあとの画像の全体。
    public static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 回す回数は0から3に、範囲は画像の中に収める。画像の外しか指していなければ、全体を残す。
    public init(quarterTurns: Int, rect: CGRect) {
        self.quarterTurns = (quarterTurns % 4 + 4) % 4
        let clamped = rect.standardized.intersection(Self.unitRect)
        self.rect = clamped.isNull || clamped.isEmpty ? Self.unitRect : clamped
    }

    /// 回すと幅と高さが入れ替わる。
    private var swapsSides: Bool { quarterTurns % 2 == 1 }

    /// 回したあとの画像の大きさ。
    /// - Parameter size: 向きを反映した元の大きさ。
    public func rotatedSize(of size: PixelSize) -> PixelSize {
        swapsSides ? PixelSize(width: size.height, height: size.width) : size
    }

    /// 残す範囲を、回す前の画像の画素で表す。左上が原点で、端は画素に揃え、幅と高さは1画素以上にする。
    /// - Parameter size: 向きを反映した元の大きさ。
    public func sourceRect(in size: PixelSize) -> CGRect {
        let unit = sourceUnitRect
        func edges(_ low: CGFloat, _ high: CGFloat, length: Int) -> (Int, Int) {
            let start = min(max(Int((low * CGFloat(length)).rounded()), 0), length - 1)
            let end = min(max(Int((high * CGFloat(length)).rounded()), start + 1), length)
            return (start, end)
        }
        let (left, right) = edges(unit.minX, unit.maxX, length: size.width)
        let (top, bottom) = edges(unit.minY, unit.maxY, length: size.height)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 切り抜いて回したあとの大きさ。
    /// - Parameter size: 向きを反映した元の大きさ。
    public func outputSize(of size: PixelSize) -> PixelSize {
        let source = sourceRect(in: size)
        let cropped = PixelSize(width: Int(source.width), height: Int(source.height))
        return swapsSides ? PixelSize(width: cropped.height, height: cropped.width) : cropped
    }

    /// 回さず、画素に揃えると全体を残すなら、切り抜かないのと同じ。
    /// - Parameter size: 向きを反映した元の大きさ。
    public func isIdentity(in size: PixelSize) -> Bool {
        quarterTurns == 0 && sourceRect(in: size) == CGRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    /// 2つの範囲が、同じ向きで同じ画素を残すか。nilは切り抜かないこととして比べる。
    /// トリミングの画面は、範囲を画面の座標と倍率から割合に直すので、同じ範囲を選び直しても割合が丸めの誤差でずれる。
    /// - Parameter size: 向きを反映した元の大きさ。
    public static func selectsSamePixels(_ lhs: ImageCrop?, _ rhs: ImageCrop?, in size: PixelSize) -> Bool {
        let identity = ImageCrop(quarterTurns: 0, rect: unitRect)
        let left = lhs ?? identity, right = rhs ?? identity
        return left.quarterTurns == right.quarterTurns && left.sourceRect(in: size) == right.sourceRect(in: size)
    }

    /// 残す範囲を、回す前の画像の割合で表す。時計回りに1回回すと、元の点(x, y)は(1 - y, x)に移る。その逆をたどる。
    private var sourceUnitRect: CGRect {
        switch quarterTurns {
        case 1: CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        case 2: CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 3: CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        default: rect
        }
    }
}

/// トリミングの画面で、枠の大きさを変えるハンドル。
public enum CropHandle: Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}

/// トリミングの画面の枠の計算。座標は画面の点で、枠の外には画像の端を入れない前提で`bounds`を渡す。
public enum CropBox {
    /// `bounds`に収まる、縦横比`aspectRatio`（幅÷高さ）の一番大きい枠。`bounds`の中央に置く。
    public static func fit(aspectRatio: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspectRatio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let size = bounds.width / bounds.height > aspectRatio
            ? CGSize(width: bounds.height * aspectRatio, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// ハンドルを`translation`だけ動かした枠。動かさない側の辺は固定し、`bounds`の外に出さず、どの辺も`minimumSide`より短くしない。
    /// `bounds`が狭くて`minimumSide`を守れないときは、`bounds`に収めるほうを優先する。
    /// - Parameter aspectRatio: 縦横比（幅÷高さ）を決めていれば、それを保つ。角のハンドルは対角の角を、辺のハンドルは向かいの辺の中央を固定する。
    public static func resize(
        _ box: CGRect,
        handle: CropHandle,
        by translation: CGVector,
        within bounds: CGRect,
        minimumSide: CGFloat,
        aspectRatio: CGFloat?
    ) -> CGRect {
        if let aspectRatio, aspectRatio > 0 {
            return handle.isCorner
                ? resizeCorner(box, handle: handle, by: translation, within: bounds, minimumSide: minimumSide, aspectRatio: aspectRatio)
                : resizeEdge(box, handle: handle, by: translation, within: bounds, minimumSide: minimumSide, aspectRatio: aspectRatio)
        }
        var minX = box.minX, maxX = box.maxX, minY = box.minY, maxY = box.maxY
        if handle.movesLeft { minX = clamp(box.minX + translation.dx, bounds.minX, max(box.maxX - minimumSide, bounds.minX)) }
        if handle.movesRight { maxX = clamp(box.maxX + translation.dx, min(box.minX + minimumSide, bounds.maxX), bounds.maxX) }
        if handle.movesTop { minY = clamp(box.minY + translation.dy, bounds.minY, max(box.maxY - minimumSide, bounds.minY)) }
        if handle.movesBottom { maxY = clamp(box.maxY + translation.dy, min(box.minY + minimumSide, bounds.maxY), bounds.maxY) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 角のハンドル。指の動きで決まる幅と、高さから比率で決まる幅の平均を新しい幅にする。どちらか一方の向きに動かしても大きさが変わるようにするため。
    private static func resizeCorner(_ box: CGRect, handle: CropHandle, by translation: CGVector, within bounds: CGRect, minimumSide: CGFloat, aspectRatio: CGFloat) -> CGRect {
        let anchor = CGPoint(x: handle.movesLeft ? box.maxX : box.minX, y: handle.movesTop ? box.maxY : box.minY)
        let proposedWidth = box.width + (handle.movesLeft ? -translation.dx : translation.dx)
        let proposedHeight = box.height + (handle.movesTop ? -translation.dy : translation.dy)
        let room = CGSize(
            width: handle.movesLeft ? anchor.x - bounds.minX : bounds.maxX - anchor.x,
            height: handle.movesTop ? anchor.y - bounds.minY : bounds.maxY - anchor.y
        )
        let maximumWidth = min(room.width, room.height * aspectRatio)
        let minimumWidth = max(minimumSide, minimumSide * aspectRatio)
        let width = min(max((proposedWidth + proposedHeight * aspectRatio) / 2, minimumWidth), maximumWidth)
        let height = width / aspectRatio
        return CGRect(
            x: handle.movesLeft ? anchor.x - width : anchor.x,
            y: handle.movesTop ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
    }

    /// 辺のハンドル。動かした向きの長さを指で決め、もう一方の長さは比率で決めて、向かいの辺の中央を中心に広げる。
    private static func resizeEdge(_ box: CGRect, handle: CropHandle, by translation: CGVector, within bounds: CGRect, minimumSide: CGFloat, aspectRatio: CGFloat) -> CGRect {
        let minimumWidth = max(minimumSide, minimumSide * aspectRatio)
        if handle.movesLeft || handle.movesRight {
            let anchorX = handle.movesLeft ? box.maxX : box.minX
            let room = handle.movesLeft ? anchorX - bounds.minX : bounds.maxX - anchorX
            let maximumWidth = min(room, 2 * min(box.midY - bounds.minY, bounds.maxY - box.midY) * aspectRatio)
            let proposed = box.width + (handle.movesLeft ? -translation.dx : translation.dx)
            let width = min(max(proposed, minimumWidth), maximumWidth)
            let height = width / aspectRatio
            return CGRect(x: handle.movesLeft ? anchorX - width : anchorX, y: box.midY - height / 2, width: width, height: height)
        }
        let anchorY = handle.movesTop ? box.maxY : box.minY
        let room = handle.movesTop ? anchorY - bounds.minY : bounds.maxY - anchorY
        let maximumHeight = min(room, 2 * min(box.midX - bounds.minX, bounds.maxX - box.midX) / aspectRatio)
        let proposed = box.height + (handle.movesTop ? -translation.dy : translation.dy)
        let height = min(max(proposed, minimumWidth / aspectRatio), maximumHeight)
        let width = height * aspectRatio
        return CGRect(x: box.midX - width / 2, y: handle.movesTop ? anchorY - height : anchorY, width: width, height: height)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

/// トリミングで画像と枠をまとめて回すときの、見た目の変形。中心のまわりに、拡大縮小してから回し、移動する。
///
/// 行列で持つと、続けて回して角度が180°を超えたときに、近い向きへ戻る補間で逆に回ってしまう。角度をそのまま足して持ち、値ごとに補間する。
public struct CropRotationPose: Sendable, Equatable {
    /// 回す角度（ラジアン）。画面の上で時計回りが正（UIKitと同じ）。
    public var angle: CGFloat
    public var scale: CGFloat
    public var translation: CGVector

    public init(angle: CGFloat, scale: CGFloat, translation: CGVector) {
        self.angle = angle
        self.scale = scale
        self.translation = translation
    }

    public static let identity = CropRotationPose(angle: 0, scale: 1, translation: .zero)

    /// 反時計回りに90度回したあとの枠`rotated`を、回す前の枠`original`に重ねる変形。回したあとの中身を時計回りに90度回し、前の枠の大きさに合わせる。
    /// - Parameter center: 変形の中心。`UIView.transform`の中心（ビューの中央）を渡す。
    public static func undoingCounterclockwiseTurn(from rotated: CGRect, to original: CGRect, around center: CGPoint) -> CropRotationPose {
        let scale = rotated.height > 0 ? original.width / rotated.height : 1
        let pose = CropRotationPose(angle: .pi / 2, scale: scale, translation: .zero)
        let moved = pose.applyingLinear(to: CGVector(dx: rotated.midX - center.x, dy: rotated.midY - center.y))
        return CropRotationPose(
            angle: pose.angle,
            scale: scale,
            translation: CGVector(dx: original.midX - center.x - moved.dx, dy: original.midY - center.y - moved.dy)
        )
    }

    /// 先にこの変形を当て、その上に`outer`を当てた変形。回している途中に続けて回すとき、見えている変形の上に重ねるのに使う。
    public func followed(by outer: CropRotationPose) -> CropRotationPose {
        let moved = outer.applyingLinear(to: translation)
        return CropRotationPose(
            angle: angle + outer.angle,
            scale: scale * outer.scale,
            translation: CGVector(dx: outer.translation.dx + moved.dx, dy: outer.translation.dy + moved.dy)
        )
    }

    /// 変形なしへ`fraction`（0から1）だけ近づけた変形。角度と倍率はまっすぐ補間し、`pivot`の見えている位置も、
    /// 始めの位置から`pivot`そのものへまっすぐ動かす。移動は、その位置に`pivot`が来るよう決め直す。
    /// 移動もまっすぐ補間すると、`center`のまわりに回る分と打ち消し合わず、`pivot`が曲線を描いて外れる。
    /// - Parameters:
    ///   - pivot: 回す軸にする点。回したあとの枠の中心を渡す。
    ///   - center: 変形の中心。`UIView.transform`の中心（ビューの中央）を渡す。
    public func approachingIdentity(fraction: CGFloat, pivot: CGPoint, around center: CGPoint) -> CropRotationPose {
        let fromCenter = CGVector(dx: pivot.x - center.x, dy: pivot.y - center.y)
        let moved = applyingLinear(to: fromCenter)
        let startPivot = CGPoint(x: center.x + translation.dx + moved.dx, y: center.y + translation.dy + moved.dy)
        let shownPivot = CGPoint(x: startPivot.x + (pivot.x - startPivot.x) * fraction, y: startPivot.y + (pivot.y - startPivot.y) * fraction)
        var pose = CropRotationPose(angle: angle * (1 - fraction), scale: scale + (1 - scale) * fraction, translation: .zero)
        let turned = pose.applyingLinear(to: fromCenter)
        pose.translation = CGVector(dx: shownPivot.x - center.x - turned.dx, dy: shownPivot.y - center.y - turned.dy)
        return pose
    }

    /// 中心のまわりの変形として、`UIView.transform`にそのまま使える形。
    public var affineTransform: CGAffineTransform {
        var transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
        transform.tx = translation.dx
        transform.ty = translation.dy
        return transform
    }

    /// 中心からの位置`vector`を、拡大縮小して回す。
    func applyingLinear(to vector: CGVector) -> CGVector {
        let cosine = cos(angle), sine = sin(angle)
        return CGVector(dx: scale * (cosine * vector.dx - sine * vector.dy), dy: scale * (sine * vector.dx + cosine * vector.dy))
    }
}
