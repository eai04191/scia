import Foundation
import SciaCore
import Testing
@testable import Scia

/// AV1をハードウェアで読めない端末（シミュレーターなど）では、AVIFをソフトウェアのデコーダーが読む。
/// 協調スレッドでたくさん同時に読むと止まっていたので、シミュレーターで走るアプリのテストで確かめる。Macのテストでは、ハードウェアで読む端末だと再現しない。
/// 止まると、このテストは戻らない。協調スレッドがすべて埋まるので、Swift Testingの時間の上限（`.timeLimit`）も働かない。
struct ImageDecoderAVIFTests {
    /// 同梱した見本の写真（AVIF）を、協調スレッドの数より多く同時に読んでも、止まらずにすべて読める。
    @Test func decodesManyAVIFsAtOnce() async throws {
        let photos = try [PreviewPhoto.tall, .wide, .gridFirst, .gridSecond].map { photo in
            try Data(contentsOf: try #require(Bundle.main.url(forResource: photo.rawValue, withExtension: "avif")))
        }
        let count = 64
        let decoded = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<count {
                let data = photos[index % photos.count]
                group.addTask { await ImageDecoder.thumbnail(of: data, maxPixelSize: 600, dynamicRange: .high) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(decoded == count)
    }
}
