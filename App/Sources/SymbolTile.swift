import SwiftUI
import UIKit

/// iOS 27.2の設定アプリのアイコンと同じ描き方で、システムカラーを敷いた角丸の四角に白い記号を描く。値は、シミュレーターで設定アプリとSciaを撮り、画素を比べて合わせた。
struct SymbolTile: View {
    static let baseSide: CGFloat = 28
    let systemImage: String
    let color: UIColor
    var squareBackground = false
    var showsRim = true
    var side: CGFloat = SymbolTile.baseSide
    var decorationScale: CGFloat = 1
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(systemName: systemImage)
            // 記号は四角の中に描く絵なので、四角の一辺から大きさを決める。
            // 設定アプリは記号ごとに太さも変えていて、大きさまで一致した3つのうち、歯車と砂時計はmedium、アクセシビリティはregularに近かった。
            // scialint:disable:next fixed_font_size
            .font(.system(size: glyphSize, weight: .medium))
            // Formの行のLabelは記号を大きく描くので、大きさを固定する。
            .imageScale(.medium)
            // 記号は、下へ行くほどわずかに下の色が透ける。
            .foregroundStyle(LinearGradient(colors: [.white, Color(uiColor: .dimmedWhiteText(alpha: 0.97))], startPoint: .top, endPoint: .bottom))
            // 記号の影は下にだけ落ち、上と横にはほとんど出ない。濃さは記号によって違い、歯車の歯の下はアクセシビリティの円の下より濃かったので、両方の差の合計が小さくなる値にした。
            .shadow(color: .black.opacity(0.12), radius: 0.6 * decorationScale, y: decorationScale)
            .frame(width: side, height: side)
            .background { tile }
    }

    private var glyphSize: CGFloat {
        Self.glyphPointSize(side: side, systemImage: systemImage)
    }

    /// 記号を描く大きさ。設定アプリの記号は、一辺の2/3の大きさで描いたものと、円の直径も線の太さも一致した（歯車とアクセシビリティ）。設定アプリで測った10個の記号のうち7個は、見た目の縦横の大きいほうが一辺の2/3に収まっていたので、2/3で描くとそれを超える記号（カメラ、写真など）は、収まるまで縮める。小さい記号は大きくしない。収まっていなかったのは、歯車、スタンバイ、一般の「フォント」の3つで、設定アプリが記号ごとに決めた大きさなので合わせていない。
    static func glyphPointSize(side: CGFloat, systemImage: String) -> CGFloat {
        let size = side * 2 / 3
        guard let ratio = visualExtentRatio(of: systemImage), ratio > 1 else { return size }
        return size / ratio
    }

    private static var extentRatios: [String: CGFloat] = [:]

    /// 記号を描いたときの、見た目の縦横の大きいほうの、描いた大きさに対する割合。`UIImage`の大きさは見た目より大きく出るので、描いた画素の範囲で測る。記号ごとに1回だけ描いて覚える。
    static func visualExtentRatio(of systemImage: String) -> CGFloat? {
        if let ratio = extentRatios[systemImage] { return ratio }
        let pointSize: CGFloat = 100
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = UIImage(systemName: systemImage, withConfiguration: configuration) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: .zero)
        }
        guard let extent = drawn.cgImage.flatMap(opaqueExtent) else { return nil }
        let ratio = extent / pointSize
        extentRatios[systemImage] = ratio
        return ratio
    }

    /// 透明でない画素の範囲の、縦横の大きいほう（画素の数）。
    private static func opaqueExtent(of image: CGImage) -> CGFloat? {
        let width = image.width, height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drew = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 127 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGFloat(max(maxX - minX + 1, maxY - minY + 1))
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: squareBackground ? 0 : side * 0.265, style: .continuous)
        let base = Color(uiColor: color.resolvedColor(with: Self.tileTraits(contrast: contrast)))
        let hairline = decorationScale / displayScale
        return ZStack {
            shape.fill(base)
            // 上へ行くほど明るい。設定アプリの四角は、上の端で下の端の約1.09倍の値になり、色の割合は変わらない。同じ色を足して明るくする。
            shape.fill(base)
                .mask(LinearGradient(colors: [.white.opacity(0.085), .clear], startPoint: .top, endPoint: .bottom))
                .blendMode(.plusLighter)
            if showsRim {
                // フチは、上と下で明るく、横の真ん中では暗い。いちばん外の1画素が明るく、上ではその内側の1画素もわずかに明るい。
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.2),
                            .init(color: .black.opacity(0.065), location: 0.5),
                            .init(color: .clear, location: 0.8),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: hairline
                )
                shape.strokeBorder(Self.rim(top: 0.24, bottom: 0.18), lineWidth: hairline)
                    .blendMode(.plusLighter)
                shape.strokeBorder(Self.rim(top: 0.045, bottom: 0.02), lineWidth: hairline * 2)
                    .blendMode(.plusLighter)
            }
        }
        .compositingGroup()
    }

    private static func rim(top: Double, bottom: Double) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(top), location: 0),
                .init(color: .clear, location: 0.3),
                .init(color: .clear, location: 0.7),
                .init(color: .white.opacity(bottom), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 四角の色は、ライトモードとダークモードで変えない。設定アプリの四角は、どちらのモードでもライトモードの版のシステムカラーで、「コントラストを上げる」ではライトモードの高コントラスト版になる。ダークモードの高コントラスト版は暗い背景との差を広げるために明るくなり、白い記号が見えにくくなる。
    private static func tileTraits(contrast: ColorSchemeContrast) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = .light
            traits.accessibilityContrast = contrast == .increased ? .high : .normal
        }
    }
}
