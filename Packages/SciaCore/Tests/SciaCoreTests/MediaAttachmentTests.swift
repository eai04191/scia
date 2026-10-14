import CoreGraphics
import Foundation
import Testing
@testable import SciaCore

struct MediaAttachmentTests {
    private func decodeFixture() throws -> Status {
        let url = try #require(Bundle.module.url(forResource: "status_with_media", withExtension: "json", subdirectory: "Fixtures"))
        return try MastodonDecoder.make().decode(Status.self, from: Data(contentsOf: url))
    }

    @Test func decodesEachKindOfAttachment() throws {
        let status = try decodeFixture()

        #expect(status.sensitive)
        #expect(status.mediaAttachments.map(\.type) == [.image, .video, .audio, .unknown("unknown")])
        let image = status.mediaAttachments[0]
        #expect(image.description == "代替テキスト")
        #expect(image.aspectRatio == 640.0 / 480.0)
        #expect(status.mediaAttachments[1].aspectRatio == 1280.0 / 720.0)
        // 音声は大きさを持たない。
        #expect(status.mediaAttachments[2].aspectRatio == nil)
        // 処理中や扱えない種類のファイルは、元のファイルのURLがない。
        #expect(status.mediaAttachments[3].url == nil)
        #expect(status.mediaAttachments[3].remoteUrl?.absoluteString == "https://remote.example/files/document.pdf")
    }

    /// エンコードして読み直しても添付ファイルが残る。ストリーミングのテストで投稿をエンコードして流すため。
    @Test func roundTripsThroughEncoding() throws {
        let status = try decodeFixture()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        let decoded = try MastodonDecoder.make().decode(Status.self, from: encoder.encode(status))

        #expect(decoded.mediaAttachments == status.mediaAttachments)
        #expect(decoded.sensitive)
    }
}

struct MediaGridLayoutTests {
    private func layout(_ ratios: [Double?], width: CGFloat = 300) -> MediaGridLayout {
        MediaGridLayout(aspectRatios: ratios, width: width, spacing: 4, tallestAspectRatio: 0.75, widestAspectRatio: 3)
    }

    @Test func noAttachmentsTakeNoSpace() {
        let grid = layout([])
        #expect(grid.height == 0)
        #expect(grid.frames.isEmpty)
        #expect(grid.aspectRatio == nil)
    }

    @Test func singleAttachmentKeepsItsAspectRatioWithinLimits() {
        #expect(layout([2]).height == 150)
        // 縦長すぎるものは、上限の比率で切り落とす。
        #expect(layout([0.25]).height == 400)
        // 横長すぎるものも同じ。
        #expect(layout([10]).height == 100)
        #expect(layout([10]).aspectRatio == 3)
        // 大きさが分からなければ16:9にする。
        #expect(abs(layout([nil]).height - 168.75) < 0.001)
        #expect(layout([2]).frames == [CGRect(x: 0, y: 0, width: 300, height: 150)])
    }

    /// 2つ以上は、比率によらず16:9の枠に並べる。
    @Test func multipleAttachmentsShareA16To9Grid() {
        let width: CGFloat = 304
        let height = width / (16.0 / 9.0)
        #expect(layout([0.5, 3], width: width).frames == [
            CGRect(x: 0, y: 0, width: 150, height: height),
            CGRect(x: 154, y: 0, width: 150, height: height),
        ])
        let three = layout([1, 1, 1], width: width)
        #expect(three.frames[0].height == height)
        #expect(three.frames[1].maxY + 4 == three.frames[2].minY)
        #expect(three.frames[2].maxY == height)
        let four = layout([1, 1, 1, 1], width: width)
        #expect(four.frames.map(\.minX) == [0, 154, 0, 154])
        #expect(four.height == height)
    }

    @Test func attachmentsBeyondFourAreCounted() {
        let grid = layout(Array(repeating: 1, count: 6))
        #expect(grid.frames.count == 4)
        #expect(grid.hiddenCount == 2)
    }
}
