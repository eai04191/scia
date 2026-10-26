import Testing
@testable import SciaCore

struct PhotoStackVariationTests {
    /// 一覧の既定の置き方（ずらす量は写真の一辺に対する割合）。
    private let base = [
        PhotoStackPlacement(rotation: -1),
        PhotoStackPlacement(rotation: 3, offsetX: 0.155, offsetY: 0.04),
        PhotoStackPlacement(rotation: -3, offsetX: -0.115, offsetY: -0.04),
    ]

    private func vary(_ seed: String, rotation: Double = 1, offset: Double = 0.03) -> [PhotoStackPlacement] {
        PhotoStackVariation.placements(base, seed: seed, maximumRotation: rotation, maximumOffset: offset)
    }

    /// 同じ投稿は、いつ描いても同じ形にする。
    @Test func sameSeedGivesSamePlacements() {
        #expect(vary("115000000000000001") == vary("115000000000000001"))
    }

    /// 投稿が違えば、形も違う。
    @Test func differentSeedsGiveDifferentPlacements() {
        let shapes = Set((0..<20).map { "\(vary("1150000000000000\($0)"))" })
        #expect(shapes.count > 15)
    }

    /// 回す向きとのぞかせる側を変えず、基準の値の半分より0に近づけず、幅の外へ出さない。1枚目のずらす量は変えない。
    @Test func variationKeepsDirectionsWithinRange() {
        for index in 0..<200 {
            let varied = vary("\(index)")
            #expect(varied[0].offsetX == 0 && varied[0].offsetY == 0)
            for (placement, original) in zip(varied, base) {
                for (value, origin, range) in [(placement.rotation, original.rotation, 1.0), (placement.offsetX, original.offsetX, 0.03), (placement.offsetY, original.offsetY, 0.03)] where origin != 0 {
                    #expect((value > 0) == (origin > 0), "向きが変わりました: \(origin) → \(value)")
                    #expect(abs(value) >= abs(origin) / 2 - 1e-9, "0に近づきすぎました: \(origin) → \(value)")
                    #expect(abs(value - origin) <= range + 1e-9, "幅の外です: \(origin) → \(value)")
                }
            }
        }
    }

    /// 角度を0にした写真はまっすぐのまま、幅を0にすれば基準のまま。
    @Test func zeroStaysZeroAndZeroRangeKeepsBase() {
        let straight = PhotoStackVariation.placements(
            [PhotoStackPlacement(rotation: 0), PhotoStackPlacement(rotation: 0, offsetX: 0.155, offsetY: 0.04)],
            seed: "1",
            maximumRotation: 1,
            maximumOffset: 0.03
        )
        #expect(straight.allSatisfy { $0.rotation == 0 })
        #expect(vary("1", rotation: 0, offset: 0) == base)
    }
}
