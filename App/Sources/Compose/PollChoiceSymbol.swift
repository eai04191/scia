import SwiftUI

/// 投票の選び方のボタンのアイコン。`checklist`（1つ選ぶ）と`checklist.checked`（複数選ぶ）の形を自前で描き、横線を動かさずに、先頭の形だけを丸から四角へ変える。
///
/// 大きさと位置は、隠して置いた`checklist`のシンボルの枠に合わせる。文字の大きさと「文字を太くする」に、ほかのボタンのシンボルと同じように追従させるため。
struct PollChoiceSymbol: View {
    let multiple: Bool

    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        let metrics = PollChoiceSymbolMetrics.interpolated(legibilityWeight == .bold ? PollChoiceSymbolMetrics.boldTextWeight : 0)
        Image(systemName: "checklist")
            .hidden()
            .overlay { PollChoiceSymbolDrawing(progress: multiple ? 1 : 0, metrics: metrics) }
            .accessibilityHidden(true)
    }
}

/// 部品を重ねて描く。下の段は、輪の内側を不透明度で埋め、チェックマークを書き順に線を引いて出す。
/// 内側の丸を縮めたり、チェックマークを拡大して出したりしない。途中のコマが、輪にもチェックマークにも読めない形になるため。
@Animatable
private struct PollChoiceSymbolDrawing: View {
    var progress: CGFloat
    @AnimatableIgnored var metrics: PollChoiceSymbolMetrics

    var body: some View {
        let progress = min(max(progress, 0), 1)
        // 内側を埋め終えてから、チェックマークを引き始める。消えかけの丸と引き始めの線を重ねない。
        let holeOpacity = 1 - min(progress / 0.45, 1)
        let drawn = max((progress - 0.45) / 0.55, 0)
        ZStack {
            PollChoiceSymbolShape(progress: progress, part: .fill, metrics: metrics)
            Group {
                PollChoiceSymbolShape(progress: progress, part: .check(row: metrics.topRowY), metrics: metrics)
                PollChoiceSymbolShape(progress: progress, part: .hole, metrics: metrics)
                    .opacity(holeOpacity)
                PollChoiceSymbolShape(progress: progress, part: .check(row: metrics.bottomRowY), metrics: metrics)
                    .mask {
                        PollChoiceSymbolShape(progress: progress, part: .checkStroke(row: metrics.bottomRowY, drawn: drawn), metrics: metrics)
                    }
            }
            .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

/// シンボルのテンプレート（100pt、小のスケール）の座標で書いた、部品の寸法。yは下が正で、ベースラインが0。
struct PollChoiceSymbolMetrics {
    /// 左右の余白を含む幅。
    var advance: CGFloat
    var capHeight: CGFloat
    var lineMinX: CGFloat
    var lineMaxX: CGFloat
    var lineThickness: CGFloat
    var markerCenterX: CGFloat
    var markerDiameter: CGFloat
    /// 選んでいない選択肢の輪の、内側の直径。
    var holeDiameter: CGFloat
    var topRowY: CGFloat
    var bottomRowY: CGFloat
    /// 上の段のチェックマークの輪郭の点。`checkCommands`の順に使う。
    var check: [CGPoint]
    /// 上の段のチェックマークの線の中心を、書き順に通る3点。
    var checkStroke: [CGPoint]
    var checkStrokeWidth: CGFloat

    /// 「文字を太くする」のときに、標準と極太の間で使う位置。
    static let boldTextWeight: CGFloat = 0.4
    /// 四角にしたときの一辺の、丸の直径に対する割合。投票の欄の選択肢の先頭のマークと同じ比にする。
    static var squareSideRatio: CGFloat { ComposePollOptionMark.squareSideRatio / ComposePollOptionMark.circleDiameterRatio }
    /// 四角にしたときのradiusの、一辺に対する割合。
    static var squareCornerRatio: CGFloat { ComposePollOptionMark.squareCornerRatio / ComposePollOptionMark.squareSideRatio }

    static let checkCommands = "MCLCCCLLCCCLC"

    static let regular = PollChoiceSymbolMetrics(
        advance: 106.05,
        capHeight: 70.459,
        lineMinX: 51.5625,
        lineMaxX: 96.2891,
        lineThickness: 7.0312,
        markerCenterX: 26.4649,
        markerDiameter: 33.3985,
        holeDiameter: 20.7031,
        topRowY: -57.1534,
        bottomRowY: -13.1836,
        check: [
            CGPoint(x: 24.5117, y: -48.291), CGPoint(x: 23.6328, y: -48.291), CGPoint(x: 23.0469, y: -48.7793), CGPoint(x: 22.4121, y: -49.4629),
            CGPoint(x: 18.3105, y: -54.4434), CGPoint(x: 17.9688, y: -54.9316), CGPoint(x: 17.8223, y: -55.4199), CGPoint(x: 17.8223, y: -56.1035),
            CGPoint(x: 17.8223, y: -57.2754), CGPoint(x: 18.7012, y: -58.2031), CGPoint(x: 19.8242, y: -58.2031), CGPoint(x: 20.6055, y: -58.2031),
            CGPoint(x: 21.1426, y: -57.9102), CGPoint(x: 21.7285, y: -57.1289), CGPoint(x: 24.4141, y: -53.6133), CGPoint(x: 30.957, y: -64.1602),
            CGPoint(x: 31.3965, y: -64.9414), CGPoint(x: 32.0312, y: -65.332), CGPoint(x: 32.8125, y: -65.332), CGPoint(x: 33.9355, y: -65.332),
            CGPoint(x: 34.9121, y: -64.4531), CGPoint(x: 34.9121, y: -63.3789), CGPoint(x: 34.9121, y: -62.8418), CGPoint(x: 34.7656, y: -62.3535),
            CGPoint(x: 34.375, y: -61.7188), CGPoint(x: 26.6602, y: -49.4629), CGPoint(x: 26.1719, y: -48.7305), CGPoint(x: 25.3906, y: -48.291),
            CGPoint(x: 24.5117, y: -48.291),
        ],
        checkStroke: [CGPoint(x: 19.82, y: -56.15), CGPoint(x: 24.5, y: -50.35), CGPoint(x: 32.81, y: -63.3)],
        checkStrokeWidth: 4.1
    )

    static let black = PollChoiceSymbolMetrics(
        advance: 117.14,
        capHeight: 70.459,
        lineMinX: 56.9336,
        lineMaxX: 107.373,
        lineThickness: 12.6953,
        markerCenterX: 28.4668,
        markerDiameter: 37.4024,
        holeDiameter: 15.4296,
        topRowY: -57.3975,
        bottomRowY: -12.9883,
        check: [
            CGPoint(x: 26.2207, y: -47.2656), CGPoint(x: 25.0977, y: -47.2656), CGPoint(x: 24.1699, y: -47.8027), CGPoint(x: 23.5352, y: -48.584),
            CGPoint(x: 19.2383, y: -53.6133), CGPoint(x: 18.6523, y: -54.3457), CGPoint(x: 18.4082, y: -54.834), CGPoint(x: 18.4082, y: -55.5176),
            CGPoint(x: 18.4082, y: -57.1777), CGPoint(x: 19.6777, y: -58.3984), CGPoint(x: 21.2402, y: -58.3984), CGPoint(x: 22.2168, y: -58.3984),
            CGPoint(x: 22.7539, y: -58.0078), CGPoint(x: 23.3887, y: -57.3242), CGPoint(x: 26.2207, y: -54.248), CGPoint(x: 33.0078, y: -64.9902),
            CGPoint(x: 33.6914, y: -66.1133), CGPoint(x: 34.5215, y: -66.6016), CGPoint(x: 35.5957, y: -66.6016), CGPoint(x: 37.207, y: -66.6016),
            CGPoint(x: 38.5742, y: -65.4297), CGPoint(x: 38.5742, y: -63.8672), CGPoint(x: 38.5742, y: -63.2812), CGPoint(x: 38.4277, y: -62.7441),
            CGPoint(x: 37.9395, y: -62.0117), CGPoint(x: 28.9062, y: -48.7793), CGPoint(x: 28.2715, y: -47.8516), CGPoint(x: 27.2461, y: -47.2656),
            CGPoint(x: 26.2207, y: -47.2656),
        ],
        checkStroke: [CGPoint(x: 21.24, y: -55.55), CGPoint(x: 26.22, y: -50.1), CGPoint(x: 35.6, y: -63.75)],
        checkStrokeWidth: 5.7
    )

    /// 標準（0）と極太（1）の間の寸法。
    static func interpolated(_ weight: CGFloat) -> PollChoiceSymbolMetrics {
        func mix(_ keyPath: KeyPath<PollChoiceSymbolMetrics, CGFloat>) -> CGFloat {
            regular[keyPath: keyPath] + (black[keyPath: keyPath] - regular[keyPath: keyPath]) * weight
        }
        return PollChoiceSymbolMetrics(
            advance: mix(\.advance),
            capHeight: mix(\.capHeight),
            lineMinX: mix(\.lineMinX),
            lineMaxX: mix(\.lineMaxX),
            lineThickness: mix(\.lineThickness),
            markerCenterX: mix(\.markerCenterX),
            markerDiameter: mix(\.markerDiameter),
            holeDiameter: mix(\.holeDiameter),
            topRowY: mix(\.topRowY),
            bottomRowY: mix(\.bottomRowY),
            check: mixPoints(\.check, weight),
            checkStroke: mixPoints(\.checkStroke, weight),
            checkStrokeWidth: mix(\.checkStrokeWidth)
        )
    }

    private static func mixPoints(_ keyPath: KeyPath<PollChoiceSymbolMetrics, [CGPoint]>, _ weight: CGFloat) -> [CGPoint] {
        zip(regular[keyPath: keyPath], black[keyPath: keyPath]).map { regular, black in
            CGPoint(x: regular.x + (black.x - regular.x) * weight, y: regular.y + (black.y - regular.y) * weight)
        }
    }
}

/// - `progress`: 0が「1つ選ぶ」（上が塗った丸、下が輪）、1が「複数選ぶ」（どちらも塗った四角）。
struct PollChoiceSymbolShape: Shape {
    enum Part {
        /// 横線と、選択肢の先頭の形。
        case fill
        /// 下の段の先頭の形からくり抜く、輪の内側。
        case hole
        /// 先頭の形からくり抜く、チェックマークの輪郭。`row`の段に置く。
        case check(row: CGFloat)
        /// チェックマークの線の中心を、書き始めから`drawn`の割合まで、輪郭を覆う太さでなぞった形。輪郭にマスクとして掛け、引いたところまでを見せる。
        case checkStroke(row: CGFloat, drawn: CGFloat)
    }

    var progress: CGFloat
    let part: Part
    let metrics: PollChoiceSymbolMetrics

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(max(progress, 0), 1)
        let rows = [metrics.topRowY, metrics.bottomRowY]
        var path = Path()
        switch part {
        case .fill:
            let side = metrics.markerDiameter * (1 + (PollChoiceSymbolMetrics.squareSideRatio - 1) * progress)
            let squareRadius = side * PollChoiceSymbolMetrics.squareCornerRatio
            let radius = side / 2 + (squareRadius - side / 2) * progress
            for row in rows {
                let line = CGRect(x: metrics.lineMinX, y: row - metrics.lineThickness / 2, width: metrics.lineMaxX - metrics.lineMinX, height: metrics.lineThickness)
                path.addRoundedRect(in: line, cornerSize: CGSize(width: metrics.lineThickness / 2, height: metrics.lineThickness / 2))
                let marker = CGRect(x: metrics.markerCenterX - side / 2, y: row - side / 2, width: side, height: side)
                path.addRoundedRect(in: marker, cornerSize: CGSize(width: radius, height: radius))
            }
        case .hole:
            let hole = metrics.holeDiameter
            path.addEllipse(in: CGRect(x: metrics.markerCenterX - hole / 2, y: metrics.bottomRowY - hole / 2, width: hole, height: hole))
        case let .check(row):
            path.addPath(checkPath(), transform: CGAffineTransform(translationX: 0, y: row - metrics.topRowY))
        case let .checkStroke(row, drawn):
            var center = Path()
            center.addLines(metrics.checkStroke.map { CGPoint(x: $0.x, y: $0.y + row - metrics.topRowY) })
            let style = StrokeStyle(lineWidth: metrics.checkStrokeWidth * 1.6, lineCap: .round, lineJoin: .round)
            path = center.trimmedPath(from: 0, to: min(max(drawn, 0), 1)).strokedPath(style)
        }
        return path.applying(placement(in: rect))
    }

    /// テンプレートの座標を、シンボルの枠に置く。枠の幅が余白を含む幅に、枠の縦の中央が大文字の高さの中央に当たる。
    private func placement(in rect: CGRect) -> CGAffineTransform {
        let scale = rect.width / metrics.advance
        return CGAffineTransform(translationX: rect.minX, y: rect.midY + metrics.capHeight / 2 * scale)
            .scaledBy(x: scale, y: scale)
    }

    private func checkPath() -> Path {
        var path = Path()
        var points = metrics.check[...]
        for command in PollChoiceSymbolMetrics.checkCommands {
            switch command {
            case "M":
                path.move(to: points.removeFirst())
            case "L":
                path.addLine(to: points.removeFirst())
            default:
                let control1 = points.removeFirst()
                let control2 = points.removeFirst()
                path.addCurve(to: points.removeFirst(), control1: control1, control2: control2)
            }
        }
        path.closeSubpath()
        return path
    }
}
