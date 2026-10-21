import Testing
@testable import SciaCore

struct PhotoStackScatterTests {
    /// 既定の正解（1枚目-2°、2枚目+7°で右下、3枚目-8°で左上）。
    private let base = [
        PhotoStackPlacement(rotation: -2),
        PhotoStackPlacement(rotation: 7, offsetX: 4, offsetY: 1),
        PhotoStackPlacement(rotation: -8, offsetX: -3, offsetY: -1),
    ]

    @Test func intensityGrowsWithVelocityBetweenTheThresholds() {
        #expect(PhotoStackScatter.intensity(velocity: 0, minimumVelocity: 600, maximumVelocity: 2600) == 0)
        #expect(PhotoStackScatter.intensity(velocity: 600, minimumVelocity: 600, maximumVelocity: 2600) == 0)
        #expect(PhotoStackScatter.intensity(velocity: 1600, minimumVelocity: 600, maximumVelocity: 2600) == 0.5)
        #expect(PhotoStackScatter.intensity(velocity: 9000, minimumVelocity: 600, maximumVelocity: 2600) == 1)
    }

    /// ゆっくり閉じたときは、正解の形のままにする。
    @Test func zeroIntensityKeepsTheBasePlacement() {
        var generator = SplitMix64(seed: 1)
        let result = PhotoStackScatter.scatter(base, intensity: 0, maximumRotation: 8, maximumOffset: 4, using: &generator)
        #expect(result == base)
    }

    /// 閉じるたびに変わる。
    @Test func scatterChangesEachTime() {
        var generator = SplitMix64(seed: 2)
        let first = PhotoStackScatter.scatter(base, intensity: 1, maximumRotation: 8, maximumOffset: 4, using: &generator)
        let second = PhotoStackScatter.scatter(base, intensity: 1, maximumRotation: 8, maximumOffset: 4, using: &generator)
        #expect(first != base)
        #expect(first != second)
    }

    /// 散らばっても、1枚目は動かず、下の写真はのぞく側と角度の向きを保ち、乱数の幅に収まる。
    @Test func scatterKeepsTheStackReadable() {
        var generator = SplitMix64(seed: 3)
        for _ in 0..<2000 {
            let intensity = Double.random(in: 0...1, using: &generator)
            let result = PhotoStackScatter.scatter(base, intensity: intensity, maximumRotation: 8, maximumOffset: 4, using: &generator)
            let front = result[0]
            #expect(front.offsetX == 0 && front.offsetY == 0)
            #expect(abs(front.rotation - base[0].rotation) <= 8 * intensity + 1e-9)
            for (placement, original) in zip(result.dropFirst(), base.dropFirst()) {
                let gap = placement.rotation - front.rotation
                let originalGap = original.rotation - base[0].rotation
                #expect(gap.sign == originalGap.sign)
                #expect(abs(gap) >= PhotoStackScatter.minimumAngleGap - 1e-9)
                #expect(placement.offsetX.sign == original.offsetX.sign)
                #expect(abs(placement.offsetX) >= PhotoStackScatter.minimumSideOffset - 1e-9)
                #expect(abs(placement.offsetX - original.offsetX) <= 4 * intensity + 1e-9)
                #expect(abs(placement.offsetY - original.offsetY) <= 4 * intensity + 1e-9)
            }
        }
    }

    /// 散らばると必ず正解より広がる。角度は傾いている向きへさらに傾き、下の写真は下と、のぞいている側へだけずれる。
    @Test func scatterOnlySpreadsTheStack() {
        var generator = SplitMix64(seed: 4)
        for _ in 0..<2000 {
            let result = PhotoStackScatter.scatter(base, intensity: 1, maximumRotation: 8, maximumOffset: 4, using: &generator)
            #expect(result[0].rotation <= base[0].rotation)
            #expect(result[1].rotation >= base[1].rotation)
            for (placement, original) in zip(result.dropFirst(), base.dropFirst()) {
                #expect(placement.offsetY >= original.offsetY)
                #expect(abs(placement.offsetX) >= abs(original.offsetX))
                #expect(abs(placement.rotation - result[0].rotation) >= PhotoStackScatter.minimumAngleGap - 1e-9)
            }
        }
    }
}
