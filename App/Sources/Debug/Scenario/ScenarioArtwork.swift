// このファイルの模様の描き方は、Boring Avatars（boring-avatars 2.0.4）から移したもので、次のライセンスが適用される。
//
// MIT License
//
// Copyright (c) 2021 boringdesigners
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#if DEBUG
import CoreImage
import UIKit

/// シナリオのアイコンと写真を、通信せずに端末で描く。
/// 絵を描いた写真や文字のアイコンは作り物らしさが目立つため、Boring Avatars（https://github.com/boringdesigners/boring-avatars ）の
/// 型を移して、名前から決まる抽象的な模様にする。アイコンはmarble、写真はbauhaus。色の決め方と形の置き方は、boring-avatars 2.0.4と同じにする。
/// 移した部分には、ファイルの頭のBoring AvatarsのMIT Licenseが適用される。
enum ScenarioArtwork {
    /// 青緑から朱へ寄せた5色。Boring Avatarsの既定のパレットは5色のうち2色が紫で、画面が紫に寄って見えたため替えた。
    private static let palette: [UIColor] = [0x264653, 0x2A9D8F, 0xE9C46A, 0xF4A261, 0xE76F51].map { hex in
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// 模様を描く座標の大きさ。boring-avatarsのviewBoxと同じ80にし、描くときに広げる。
    private static let unit: CGFloat = 80

    /// marbleの型のアイコンのdata URL。`seed`（ユーザー名など）から模様が決まる。
    static func avatar(_ seed: String) -> String {
        dataURL(marble(seed, side: 240))
    }

    /// bauhausの型の写真。`seed`から模様が決まる。
    static func photo(_ seed: String, size: CGSize, description: String? = nil) -> ScenarioFixtures.Picture {
        ScenarioFixtures.Picture(url: dataURL(photoImage(seed, size: size)), width: Int(size.width), height: Int(size.height), description: description)
    }

    /// bauhausの型の写真の画像。投稿欄の添付のように、data URLではなく画像のまま渡す場面に使う。
    /// 模様は正方形なので、写真の長い辺に合わせて広げ、はみ出した分を切る。
    static func photoImage(_ seed: String, size: CGSize) -> UIImage {
        let hash = hashCode(seed)
        let isSquare = boolean(hash, 2)
        let elements = (0..<4).map { index in
            let number = hash * (index + 1)
            let range = Int(unit) / 2 - (index + 17)
            return (
                color: color(hash + index),
                translation: CGPoint(x: unitValue(number, range, 1), y: unitValue(number, range, 2)),
                rotation: CGFloat(unitValue(number, 360, nil)) * .pi / 180
            )
        }
        return renderer(size: size).image { context in
            let cg = context.cgContext
            let side = max(size.width, size.height)
            cg.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            cg.scaleBy(x: side / unit, y: side / unit)
            elements[0].color.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: unit, height: unit))
            // SVGの`translate(x y) rotate(r cx cy)`と同じく、中心で回してから動かす。
            func place(_ element: (color: UIColor, translation: CGPoint, rotation: CGFloat), rotates: Bool, draw: () -> Void) {
                cg.saveGState()
                cg.translateBy(x: element.translation.x, y: element.translation.y)
                if rotates {
                    cg.translateBy(x: unit / 2, y: unit / 2)
                    cg.rotate(by: element.rotation)
                    cg.translateBy(x: -unit / 2, y: -unit / 2)
                }
                draw()
                cg.restoreGState()
            }
            place(elements[1], rotates: true) {
                elements[1].color.setFill()
                cg.fill(CGRect(x: (unit - 60) / 2, y: (unit - 20) / 2, width: unit, height: isSquare ? unit : unit / 8))
            }
            place(elements[2], rotates: false) {
                elements[2].color.setFill()
                cg.fillEllipse(in: CGRect(x: unit / 2 - unit / 5, y: unit / 2 - unit / 5, width: unit / 5 * 2, height: unit / 5 * 2))
            }
            place(elements[3], rotates: true) {
                elements[3].color.setStroke()
                cg.setLineWidth(2)
                cg.strokeLineSegments(between: [CGPoint(x: 0, y: unit / 2), CGPoint(x: unit, y: unit / 2)])
            }
        }
    }

    /// marbleの型。地の色に、2つの形をぼかして重ね、2つ目はオーバーレイで重ねる。
    private static func marble(_ seed: String, side: CGFloat) -> UIImage {
        let hash = hashCode(seed)
        let elements = (0..<3).map { index in
            let number = hash * (index + 1)
            return (
                color: color(hash + index),
                translation: CGPoint(x: unitValue(number, Int(unit) / 10, 1), y: unitValue(number, Int(unit) / 10, 2)),
                scale: 1.2 + CGFloat(unitValue(number, Int(unit) / 20, nil)) / 10,
                rotation: CGFloat(unitValue(number, 360, 1)) * .pi / 180
            )
        }
        let size = CGSize(width: side, height: side)
        let paths = marbleShapes
        // boring-avatarsは、どちらの形も3つ目の要素の大きさで広げる。
        let shapes = [
            (path: paths[0], element: elements[1], scale: elements[2].scale),
            (path: paths[1], element: elements[2], scale: elements[2].scale),
        ].map { shape in
            // SVGでは、ぼかしの標準偏差7は形の座標で効くので、形を広げた分だけ強くなる。枠の外へはみ出した形からのにじみも入るよう、ぼかす分だけ余白を取って描く。
            let sigma = 7 * shape.scale * side / unit
            let padding = (sigma * 3).rounded(.up)
            let image = transparentRenderer(size: CGSize(width: side + padding * 2, height: side + padding * 2)).image { context in
                let cg = context.cgContext
                cg.translateBy(x: padding, y: padding)
                cg.scaleBy(x: side / unit, y: side / unit)
                cg.translateBy(x: shape.element.translation.x, y: shape.element.translation.y)
                cg.translateBy(x: unit / 2, y: unit / 2)
                cg.rotate(by: shape.element.rotation)
                cg.translateBy(x: -unit / 2, y: -unit / 2)
                cg.scaleBy(x: shape.scale, y: shape.scale)
                shape.element.color.setFill()
                cg.addPath(shape.path)
                cg.fillPath()
            }
            return (image: blurred(image, sigma: sigma), padding: padding)
        }
        return renderer(size: size).image { context in
            elements[0].color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            func frame(_ shape: (image: UIImage, padding: CGFloat)) -> CGRect {
                CGRect(x: -shape.padding, y: -shape.padding, width: side + shape.padding * 2, height: side + shape.padding * 2)
            }
            shapes[0].image.draw(in: frame(shapes[0]))
            shapes[1].image.draw(in: frame(shapes[1]), blendMode: .overlay, alpha: 1)
        }
    }

    /// marbleの2つの形。boring-avatarsのSVGのパスを、そのまま点に直したもの。CGPathは`Sendable`でないので、使うたびに作る。
    private static var marbleShapes: [CGPath] {
        [
            polygon([(32.414, 59.35), (50.376, 70.5), (72.5, 70.5), (72.5, -0.5), (33.728, -0.5), (26.5, 13.381), (45.557, 40.461), (32.414, 59.35)]),
            polygon([(22.216, 24), (0, 46.75), (14.108, 84.879), (78, 86), (74.919, 26.724), (52.541, 30.729), (65.513, 50.915), (42.163, 78.31), (22.215, 24)]),
        ]
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }

    /// SVGの`feGaussianBlur`と同じく、`sigma`を標準偏差としてぼかし、元の大きさで切る。
    private static func blurred(_ image: UIImage, sigma: CGFloat) -> UIImage {
        guard let input = CIImage(image: image) else { preconditionFailure("シナリオの模様をぼかせない") }
        let output = input.applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let cgImage = CIContext().createCGImage(output, from: input.extent) else { preconditionFailure("シナリオの模様をぼかせない") }
        return UIImage(cgImage: cgImage)
    }

    // boring-avatarsの`utilities`と同じ計算。JavaScriptの数の扱い（32ビットに丸めたハッシュの絶対値）に合わせる。

    private static func hashCode(_ name: String) -> Int {
        var hash: Int32 = 0
        for unit in name.utf16 {
            hash = (hash &<< 5) &- hash &+ Int32(unit)
        }
        return abs(Int(hash))
    }

    private static func digit(_ number: Int, _ position: Int) -> Int {
        number / Int(pow(10, Double(position))) % 10
    }

    private static func boolean(_ number: Int, _ position: Int) -> Bool {
        digit(number, position).isMultiple(of: 2)
    }

    private static func unitValue(_ number: Int, _ range: Int, _ index: Int?) -> CGFloat {
        let value = number % range
        if let index, digit(number, index).isMultiple(of: 2) {
            return CGFloat(-value)
        }
        return CGFloat(value)
    }

    private static func color(_ number: Int) -> UIColor {
        palette[number % palette.count]
    }

    private static func renderer(size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private static func transparentRenderer(size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private static func dataURL(_ image: UIImage) -> String {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            preconditionFailure("シナリオの画像をJPEGにできない")
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
#endif
