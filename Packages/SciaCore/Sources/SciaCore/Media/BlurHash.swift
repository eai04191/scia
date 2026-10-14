import Foundation

/// 画像の色の分布を短い文字列にしたもの。添付ファイルを読み込まずに、ぼかした下地を描くために使う。
/// https://github.com/woltapp/blurhash/blob/master/Algorithm.md
public struct BlurHash: Sendable {
    /// 横と縦の成分の数。
    public let componentsX: Int
    public let componentsY: Int
    /// 成分ごとの色。線形RGB。先頭は全体の平均の色。
    private let colors: [(r: Double, g: Double, b: Double)]

    /// 文字列が仕様どおりでなければnil。
    public init?(_ hash: String) {
        let digits = hash.map { Self.base83Index[$0] }
        guard digits.count >= 6, digits.allSatisfy({ $0 != nil }) else { return nil }
        let values = digits.compactMap(\.self)
        let sizeFlag = values[0]
        componentsY = sizeFlag / 9 + 1
        componentsX = sizeFlag % 9 + 1
        guard values.count == 4 + 2 * componentsX * componentsY else { return nil }
        let maximumValue = Double(values[1] + 1) / 166
        colors = (0..<componentsX * componentsY).map { index in
            if index == 0 {
                return Self.decodeDC(Self.decode83(values[2..<6]))
            }
            let start = 4 + index * 2
            return Self.decodeAC(Self.decode83(values[start..<start + 2]), maximumValue: maximumValue)
        }
    }

    /// `width`×`height`ピクセルのRGBA（各8ビット、アルファは常に255）に展開する。
    public func rgba(width: Int, height: Int) -> [UInt8] {
        precondition(width > 0 && height > 0, "大きさは1以上にします")
        // 同じ値を何度も計算しないよう、軸ごとの余弦を先に求めておく。
        let cosX = (0..<width).map { x in (0..<componentsX).map { cos(Double.pi * Double(x) * Double($0) / Double(width)) } }
        let cosY = (0..<height).map { y in (0..<componentsY).map { cos(Double.pi * Double(y) * Double($0) / Double(height)) } }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<componentsY {
                    for i in 0..<componentsX {
                        let basis = cosX[x][i] * cosY[y][j]
                        let color = colors[i + j * componentsX]
                        r += color.r * basis
                        g += color.g * basis
                        b += color.b * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = Self.linearToSRGB(r)
                pixels[offset + 1] = Self.linearToSRGB(g)
                pixels[offset + 2] = Self.linearToSRGB(b)
            }
        }
        return pixels
    }

    private static let base83Index: [Character: Int] = Dictionary(
        uniqueKeysWithValues: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".enumerated().map { ($1, $0) }
    )

    private static func decode83(_ digits: ArraySlice<Int>) -> Int {
        digits.reduce(0) { $0 * 83 + $1 }
    }

    private static func decodeDC(_ value: Int) -> (r: Double, g: Double, b: Double) {
        (sRGBToLinear(value >> 16), sRGBToLinear((value >> 8) & 255), sRGBToLinear(value & 255))
    }

    private static func decodeAC(_ value: Int, maximumValue: Double) -> (r: Double, g: Double, b: Double) {
        func component(_ quantized: Int) -> Double {
            let normalized = (Double(quantized) - 9) / 9
            return copysign(normalized * normalized, normalized) * maximumValue
        }
        return (component(value / (19 * 19)), component((value / 19) % 19), component(value % 19))
    }

    private static func sRGBToLinear(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Double) -> UInt8 {
        let v = min(max(value, 0), 1)
        let srgb = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(min(max(srgb * 255 + 0.5, 0), 255))
    }
}
