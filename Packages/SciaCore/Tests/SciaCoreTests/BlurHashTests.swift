import Testing
@testable import SciaCore

struct BlurHashTests {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    /// `value`を`length`桁の83進数にする。テスト用の文字列を組み立てるために使う。
    private func base83(_ value: Int, length: Int) -> String {
        var digits: [Character] = []
        var rest = value
        for _ in 0..<length {
            digits.insert(Self.alphabet[rest % 83], at: 0)
            rest /= 83
        }
        return String(digits)
    }

    private func pixel(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[offset..<offset + 4])
    }

    /// 平均の色だけの文字列は、全体をその色で塗る。
    @Test func averageColorOnlyFillsUniformly() throws {
        let hash = "00" + base83(0xFF8000, length: 4)
        let blurHash = try #require(BlurHash(hash))

        let pixels = blurHash.rgba(width: 4, height: 3)

        #expect(pixels.count == 4 * 3 * 4)
        for y in 0..<3 {
            for x in 0..<4 {
                #expect(pixel(pixels, x: x, y: y, width: 4) == [255, 128, 0, 255])
            }
        }
    }

    /// 横方向の成分が正なら、左が明るく右が暗い。
    @Test func horizontalComponentShadesLeftToRight() throws {
        // 横2成分×縦1成分。赤だけを最大の正の値にする。
        let ac = 18 * 19 * 19 + 9 * 19 + 9
        let hash = base83(1, length: 1) + base83(82, length: 1) + base83(0x808080, length: 4) + base83(ac, length: 2)
        let blurHash = try #require(BlurHash(hash))

        let pixels = blurHash.rgba(width: 8, height: 1)
        let left = pixel(pixels, x: 0, y: 0, width: 8)
        let right = pixel(pixels, x: 7, y: 0, width: 8)

        #expect(left[0] > right[0])
        #expect(left[1] == right[1])
        #expect(left[2] == right[2])
    }

    @Test func readsComponentCountsOfRealHash() throws {
        let blurHash = try #require(BlurHash("LEHV6nWB2yk8pyo0adR*.7kCMdnj"))

        #expect(blurHash.componentsX == 4)
        #expect(blurHash.componentsY == 3)
        #expect(blurHash.rgba(width: 32, height: 24).count == 32 * 24 * 4)
    }

    @Test func rejectsMalformedHashes() {
        #expect(BlurHash("") == nil)
        #expect(BlurHash("LEHV6") == nil)
        // 成分の数と長さが合わない。
        #expect(BlurHash("LEHV6nWB2yk8pyo0adR*.7kCMdn") == nil)
        // 83進数で使わない文字を含む。
        #expect(BlurHash("LEHV6nWB2yk8pyo0adR*.7kCMdn!") == nil)
    }
}
