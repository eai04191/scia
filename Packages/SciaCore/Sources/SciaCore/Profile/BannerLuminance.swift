public import CoreGraphics
import Foundation

/// プロフィールのヘッダー画像の、上から順の行ごとの明るさ。画面の上端まで伸ばしたヘッダー画像の上に載るステータスバーの文字の色を決めるのに使う。
public struct BannerLuminance: Equatable, Sendable {
    /// 上から順に、行ごとの平均の相対輝度（0〜1）。
    public let rows: [Double]

    public init(rows: [Double]) {
        self.rows = rows
    }

    /// 縦横比が`frameAspect`（高さ÷幅）の枠に、縦横比を保って枠を埋めるように置いた画像の、枠に見えている範囲の明るさを測る。
    /// 切り落とした部分の明るさが混ざると、見えている部分と違う色の文字を選ぶため。描けない画像ならnil。
    public init?(image: CGImage, frameAspect: Double, rowCount: Int = 32, columnCount: Int = 8) {
        let size = CGSize(width: image.width, height: image.height)
        // CGImageの切り抜きは、左上を原点とする画素の範囲で指定する。`visibleRect`と同じ。
        let visible = ProfileBannerLayout.visibleRect(ofImageSized: size, inFrameWithAspect: frameAspect)
            .integral
            .intersection(CGRect(origin: .zero, size: size))
        guard !visible.isEmpty, let cropped = image.cropping(to: visible) else { return nil }
        self.init(image: cropped, rowCount: rowCount, columnCount: columnCount)
    }

    /// 画像を縦`rowCount`行、横`columnCount`列に縮めて、行ごとの相対輝度を測る。描けない画像ならnil。
    public init?(image: CGImage, rowCount: Int = 32, columnCount: Int = 8) {
        guard rowCount > 0, columnCount > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: columnCount,
                  height: rowCount,
                  bitsPerComponent: 8,
                  bytesPerRow: columnCount * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // 透過した部分は、ヘッダー画像の下地と同じく白の上に置いたものとして測る。
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: columnCount, height: rowCount))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: columnCount, height: rowCount))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowCount * columnCount * 4)
        // ビットマップの先頭の行が、画像の上端にあたる。
        rows = (0 ..< rowCount).map { row in
            let sum = (0 ..< columnCount).reduce(0.0) { sum, column in
                let offset = (row * columnCount + column) * 4
                return sum + Self.relativeLuminance(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
            }
            return sum / Double(columnCount)
        }
    }

    /// 画面の帯の下に見える明るさ。帯の位置は、ヘッダー画像の上端からの距離（下向きが正）で、ヘッダー画像の高さと同じ単位で渡す。
    /// 上端より上は、伸ばす部品が上端を境に画像を折り返してぼかして描くため、折り返した先の行を見る。画像の高さより遠い部分は、下端の行を見る。
    public func luminance(underBandFrom top: Double, to bottom: Double, bannerHeight: Double) -> Double? {
        guard !rows.isEmpty, bannerHeight > 0, bottom > top else { return nil }
        let sampleCount = 8
        let sum = (0 ..< sampleCount).reduce(0.0) { sum, index in
            let position = top + (bottom - top) * (Double(index) + 0.5) / Double(sampleCount)
            let fraction = min(abs(position) / bannerHeight, 1)
            let row = min(Int(fraction * Double(rows.count)), rows.count - 1)
            return sum + rows[row]
        }
        return sum / Double(sampleCount)
    }

    /// sRGBの色の相対輝度（WCAG 2.1）。
    static func relativeLuminance(red: UInt8, green: UInt8, blue: UInt8) -> Double {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// ステータスバーの文字の色。
public enum StatusBarTextTone: Equatable, Sendable {
    /// 白い文字。
    case light
    /// 黒い文字。
    case dark

    /// 地の相対輝度から、白と黒のうち、地とのコントラスト比（WCAG 2.1）が大きいほうを選ぶ。
    /// 白とのコントラスト比は1.05/(L+0.05)、黒とは(L+0.05)/0.05で、相対輝度が約0.18のときに等しくなる。
    public init(backgroundLuminance luminance: Double) {
        let againstWhite = 1.05 / (luminance + 0.05)
        let againstBlack = (luminance + 0.05) / 0.05
        self = againstWhite > againstBlack ? .light : .dark
    }
}
