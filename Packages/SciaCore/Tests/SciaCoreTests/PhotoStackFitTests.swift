import CoreGraphics
import Foundation
import Testing
@testable import SciaCore

struct PhotoStackFitTests {
    /// 投稿欄のカプセルの既定の置き方を、写真の一辺に対する割合にしたもの。
    private let placements = [
        PhotoStackPlacement(rotation: -2),
        PhotoStackPlacement(rotation: 7, offsetX: 0.155, offsetY: 0.04),
        PhotoStackPlacement(rotation: -8, offsetX: -0.115, offsetY: -0.04),
    ]

    /// 回していない1枚は、正方形いっぱいの大きさで真ん中に置く。
    @Test func unrotatedSinglePhotoFillsTheSquare() {
        let fit = PhotoStackFit(placements: [PhotoStackPlacement(rotation: 0)], count: 1, side: 64)
        #expect(fit.photoSide == 64)
        #expect(fit.frontCenter == CGPoint(x: 32, y: 32))
    }

    /// 回した写真は、角が正方形からはみ出さない大きさに縮める。
    @Test func rotatedPhotoShrinksToKeepItsCornersInside() {
        let fit = PhotoStackFit(placements: [PhotoStackPlacement(rotation: 45)], count: 1, side: 64)
        #expect(abs(fit.photoSide - 64 / 2.squareRoot()) < 0.001)
        #expect(abs(fit.frontCenter.x - 32) < 0.001)
    }

    /// どの数でも、回した写真の角までが正方形に収まり、長いほうの辺は正方形いっぱいになる。
    @Test(arguments: [1, 2, 3, 5])
    func stackFitsInsideTheSquare(count: Int) {
        let side: CGFloat = 64
        let fit = PhotoStackFit(placements: placements, count: count, side: side)
        let corners = placements.prefix(min(count, 3)).enumerated().flatMap { index, placement in
            let center = CGPoint(
                x: fit.frontCenter.x + (index == 0 ? 0 : placement.offsetX * fit.photoSide),
                y: fit.frontCenter.y + (index == 0 ? 0 : placement.offsetY * fit.photoSide)
            )
            let radians = placement.rotation * .pi / 180
            return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { dx, dy in
                let x = dx * fit.photoSide / 2
                let y = dy * fit.photoSide / 2
                return CGPoint(x: center.x + x * cos(radians) - y * sin(radians), y: center.y + x * sin(radians) + y * cos(radians))
            }
        }
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        #expect(minX >= -0.001 && minY >= -0.001 && maxX <= side + 0.001 && maxY <= side + 0.001)
        #expect(abs(max(maxX - minX, maxY - minY) - side) < 0.001)
    }

    /// 縮めた写真は縮めた大きさで収める。奥の写真を縮めて下からのぞかせると、手前の写真の下端から同じ幅ずつ下へ出て、正方形の下端に着く。
    @Test func scaledPhotosPeekBelowWithinTheSquare() {
        let peek = 0.07
        let shrink = 0.12
        let stacked = (0..<4).map { index in
            let scale = 1 - shrink * Double(index)
            return PhotoStackPlacement(rotation: 0, offsetY: peek * Double(index) + (1 - scale) / 2, scale: scale)
        }
        let fit = PhotoStackFit(placements: stacked, count: 4, side: 64)
        #expect(abs(fit.photoSide - 64 / (1 + peek * 3)) < 0.001)
        let lowestBottom = fit.frontCenter.y + (stacked[3].offsetY + stacked[3].scale / 2) * fit.photoSide
        #expect(abs(lowestBottom - 64) < 0.001)
        #expect(abs(fit.frontCenter.x - 32) < 0.001, "左右にずれています")
    }

    /// 重ねると、1つのときより写真が小さくなる。
    @Test func moreTilesMakeSmallerPhotos() {
        let single = PhotoStackFit(placements: placements, count: 1, side: 64)
        let triple = PhotoStackFit(placements: placements, count: 3, side: 64)
        #expect(triple.photoSide < single.photoSide)
    }
}
