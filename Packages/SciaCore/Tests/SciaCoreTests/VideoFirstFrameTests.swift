import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import SciaCore

struct VideoFirstFrameTests {
    /// ファイルの中身から求められた範囲を返し、求められた範囲を記録する。
    private final class RangeServer: Sendable {
        private let data: Data
        private let ranges = Mutex<[Range<Int>]>([])

        init(_ data: Data) {
            self.data = data
        }

        var requested: [Range<Int>] { ranges.withLock { $0 } }

        func fetch(_ range: Range<Int>) -> Data {
            ranges.withLock { $0.append(range) }
            let clamped = min(range.lowerBound, data.count)..<min(range.upperBound, data.count)
            return data.subdata(in: clamped)
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// AVFoundationで、`data`から0秒目のフレームを作る。
    private func makeFrame(from data: Data) async throws -> CGImage {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try await generator.image(at: .zero).image
    }

    /// 目次が先頭にある動画（Mastodonが処理した動画と同じ形）では、最初に読んだ部分で足り、最初のキーフレームの終わりまでで作れる。
    /// 音声のトラックが映像より前にあっても、映像のトラックを選ぶ。終わりの位置は`ffprobe`で調べた値。
    @Test func faststartVideoNeedsUpToTheFirstKeyFrame() async throws {
        let data = try fixture("video_faststart")
        #expect(VideoFirstFrame.step(prefix: data.prefix(4_000)) == .complete(3_446 + 4_057))

        let server = RangeServer(data)
        let prefix = try await VideoFirstFrame.readPrefix { server.fetch($0) }
        #expect(server.requested == [0..<VideoFirstFrame.initialLength])
        #expect(prefix.count >= 7_503)

        let frame = try await makeFrame(from: data.prefix(7_503))
        #expect(frame.width == 320)
        #expect(frame.height == 180)
    }

    /// 目次が最初に読む長さに収まらなければ、目次の終わりまで読み足し、続けて最初のキーフレームの終わりまで読む。
    @Test func readsMoreWhenTheMoovDoesNotFitTheFirstRead() async throws {
        let data = try fixture("video_long_moov_head")
        let server = RangeServer(data)

        let prefix = try await VideoFirstFrame.readPrefix { server.fetch($0) }

        #expect(server.requested == [0..<65_536, 65_536..<145_068, 145_068..<145_719])
        #expect(prefix == data.prefix(145_719))
        let frame = try await makeFrame(from: prefix)
        #expect(frame.width == 64)
    }

    /// 目次が本体より後ろにあると、先頭からは作れない。末尾を探しに行かない。
    @Test func moovAfterMediaDataIsUnsupported() async throws {
        let server = RangeServer(try fixture("video_moov_at_end"))

        await #expect(throws: VideoFirstFrame.Failure.unsupported) {
            try await VideoFirstFrame.readPrefix { server.fetch($0) }
        }
        #expect(server.requested.count == 1)
    }

    /// 要る長さが上限を超えるなら、読み足さない。
    @Test func doesNotReadBeyondTheLimit() async throws {
        let data = box("ftyp", Data(count: 8)) + header("moov", size: VideoFirstFrame.maxLength + 1) + Data(count: 100)
        let server = RangeServer(data)

        await #expect(throws: VideoFirstFrame.Failure.tooLarge) {
            try await VideoFirstFrame.readPrefix { server.fetch($0) }
        }
        #expect(server.requested.count == 1)
    }

    /// 要る長さより前でファイルが終わっていれば、読み直し続けずに諦める。
    @Test func givesUpWhenTheFileEndsEarly() async throws {
        let data = box("ftyp", Data(count: 8)) + header("moov", size: 100_000) + Data(count: 100)
        let server = RangeServer(data)

        await #expect(throws: VideoFirstFrame.Failure.truncated) {
            try await VideoFirstFrame.readPrefix { server.fetch($0) }
        }
        #expect(server.requested.count == 1)
    }

    /// 最初のキーフレームがチャンクの途中にあれば、チャンクの始まりに、前のサンプルの大きさを足した位置から始まる。
    @Test func keyFrameInTheMiddleOfAChunk() {
        // 1チャンク目にサンプル1、2チャンク目からは1チャンクに3サンプル。キーフレームは3番目で、2チャンク目の2番目。
        let moov = videoMoov(
            syncSamples: [3],
            sizes: [10, 20, 30, 40, 50],
            chunkRuns: [(1, 1), (2, 3)],
            chunkOffsets: [1_000, 2_000]
        )
        #expect(VideoFirstFrame.step(prefix: box("ftyp", Data(count: 8)) + moov) == .complete(2_000 + 20 + 30))
    }

    /// キーフレームの表がなければ、すべてのサンプルがキーフレーム。大きさがすべて同じなら、表の代わりに1つの値で書かれる。
    @Test func withoutSyncTableTheFirstSampleIsAKeyFrame() {
        let moov = videoMoov(syncSamples: nil, uniformSize: 500, chunkRuns: [(1, 4)], chunkOffsets: [3_000])
        #expect(VideoFirstFrame.step(prefix: box("ftyp", Data(count: 8)) + moov) == .complete(3_500))
    }

    /// 壊れたファイルの大きさや位置が、足すと桁あふれする値でも落ちない。他のサーバーのファイルは中身を信じられないため。
    @Test func hugeSizesAndOffsetsDoNotOverflow() {
        let ftyp = box("ftyp", Data(count: 8))
        let hugeBox = uint32(1) + Data("moov".utf8) + Data([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(VideoFirstFrame.step(prefix: ftyp + hugeBox) == .unsupported)

        let hugeOffset = videoMoov(syncSamples: nil, uniformSize: 500, chunkRuns: [(1, 1)], chunkOffsets: [], chunkOffsets64: [Int.max - 100])
        #expect(VideoFirstFrame.step(prefix: ftyp + hugeOffset) == .unsupported)
    }

    @Test func videoWithoutAVideoTrackIsUnsupported() {
        let audio = box("trak", box("mdia", box("hdlr", Data(count: 8) + Data("soun".utf8) + Data(count: 12))))
        #expect(VideoFirstFrame.step(prefix: box("ftyp", Data(count: 8)) + box("moov", audio)) == .unsupported)
    }

    // MARK: - 箱を組み立てる

    private func header(_ type: String, size: Int) -> Data {
        uint32(size) + Data(type.utf8)
    }

    private func box(_ type: String, _ payload: Data) -> Data {
        header(type, size: 8 + payload.count) + payload
    }

    private func uint32(_ value: Int) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// 版と印（4バイト）、項目の数に続く表。
    private func table(_ type: String, _ rows: [[Int]]) -> Data {
        box(type, Data(count: 4) + uint32(rows.count) + rows.flatMap { $0 }.reduce(Data()) { $0 + uint32($1) })
    }

    private func videoMoov(
        syncSamples: [Int]?,
        sizes: [Int] = [],
        uniformSize: Int = 0,
        chunkRuns: [(Int, Int)],
        chunkOffsets: [Int],
        chunkOffsets64: [Int]? = nil
    ) -> Data {
        let stsz = box("stsz", Data(count: 4) + uint32(uniformSize) + uint32(uniformSize > 0 ? 4 : sizes.count) + sizes.reduce(Data()) { $0 + uint32($1) })
        let chunkTable = if let chunkOffsets64 {
            box("co64", Data(count: 4) + uint32(chunkOffsets64.count) + chunkOffsets64.reduce(Data()) { $0 + uint32($1 >> 32) + uint32($1 & 0xFFFF_FFFF) })
        } else {
            table("stco", chunkOffsets.map { [$0] })
        }
        var stbl = stsz + table("stsc", chunkRuns.map { [$0.0, $0.1, 1] }) + chunkTable
        if let syncSamples {
            stbl = table("stss", syncSamples.map { [$0] }) + stbl
        }
        let hdlr = box("hdlr", Data(count: 8) + Data("vide".utf8) + Data(count: 12))
        let mdia = box("mdia", hdlr + box("minf", box("stbl", stbl)))
        return box("moov", box("trak", mdia))
    }
}
