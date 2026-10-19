public import Foundation

/// 動画の最初のフレームを作るのに要る、ファイルの先頭の部分を読む。
///
/// サーバーが動画から作るプレビュー画像は小さく（Mastodonは長い辺640ピクセルまで）、一覧で引き伸ばすとぼやける。
/// 元の動画の先頭だけを読めば、元の解像度の最初のフレームを作れる。要るのは、目次（moov）と最初のキーフレームの終わりまで。
/// Mastodonは動画を処理するとき`movflags faststart`で目次を先頭に置くので、先頭から順に読めば足りる。
/// https://github.com/mastodon/mastodon/blob/main/app/models/media_attachment.rb
///
/// 要る長さは画質と解像度で大きく違う（720pで64KB以下、4Kで460KBほど）ため、決まった長さでは読まず、目次から計算してちょうどそこまで読む。
public enum VideoFirstFrame {
    /// 最初に読む長さ。目次はたいていここに収まる。収まらなければ、目次の終わりまで読み足す。
    public static let initialLength = 64 * 1_024
    /// 読む長さの上限。4Kの動画でも500KBほどで足りるため、その倍を上限にし、極端な画質の動画や壊れたファイルで何MBも読まない。
    public static let maxLength = 1_024 * 1_024

    /// 先頭から読んだ部分をもとに、次に何をするか。
    public enum Step: Equatable, Sendable {
        /// 先頭からこの長さまで読めば、続きを決められる。
        case needsBytes(Int)
        /// 先頭からこの長さまであれば、最初のフレームを作れる。
        case complete(Int)
        /// 先頭からは作れない。目次が動画の本体より後ろにある、映像がない、形が読めない、のどれか。
        case unsupported
    }

    public enum Failure: Error, Equatable, Sendable {
        /// 先頭からは作れない形のファイル。
        case unsupported
        /// 要る長さが`maxLength`を超える。
        case tooLarge
        /// 要る長さより前でファイルが終わった。
        case truncated
    }

    /// `range`の部分を読む。ファイルの終わりを越えた分は返さない。
    public typealias FetchRange = @Sendable (Range<Int>) async throws -> Data

    /// 最初のフレームを作れるだけの先頭の部分を読む。作れなければ`Failure`を投げる。
    public static func readPrefix(fetch: FetchRange) async throws -> Data {
        var data = try await fetch(0..<initialLength)
        var reachedEnd = data.count < initialLength
        while true {
            let required: Int
            switch step(prefix: data) {
            case .complete(let length):
                guard length > data.count else { return data }
                required = length
            case .needsBytes(let length):
                required = length
            case .unsupported:
                throw Failure.unsupported
            }
            guard required <= maxLength else { throw Failure.tooLarge }
            guard required > data.count, !reachedEnd else { throw Failure.truncated }
            let more = try await fetch(data.count..<required)
            reachedEnd = more.count < required - data.count
            data.append(more)
        }
    }

    /// 先頭から読んだ部分（`prefix`）をもとに、要る長さを求める。
    public static func step(prefix: Data) -> Step {
        let bytes = Bytes(Array(prefix))
        var offset = 0
        while true {
            // 箱の頭は8バイトで、大きさが4GB以上の箱だけ16バイトになる。
            if offset + 8 > bytes.count || (bytes.uint32(at: offset) == 1 && offset + 16 > bytes.count) {
                return .needsBytes(offset + 16)
            }
            guard let header = bytes.boxHeader(at: offset) else { return .unsupported }
            switch header.type {
            case "moov":
                guard let end = header.end else { return .unsupported }
                guard end <= bytes.count else { return .needsBytes(end) }
                guard let frameEnd = firstKeyFrameEnd(in: bytes, moov: header.payload(upTo: end)) else { return .unsupported }
                return .complete(max(frameEnd, end))
            case "mdat":
                // 目次より先に本体がある。目次を読むには本体を越えて末尾まで読むことになる。
                return .unsupported
            default:
                guard let end = header.end else { return .unsupported }
                offset = end
            }
        }
    }

    /// 映像のトラックの最初のキーフレームが、ファイルのどこで終わるか。
    private static func firstKeyFrameEnd(in bytes: Bytes, moov: Range<Int>) -> Int? {
        guard let tracks = bytes.children(in: moov) else { return nil }
        for track in tracks where track.type == "trak" {
            guard let mdia = bytes.child("mdia", in: track.payload),
                  let handler = bytes.child("hdlr", in: mdia),
                  bytes.string(at: handler.lowerBound + 8, length: 4) == "vide"
            else { continue }
            guard let minf = bytes.child("minf", in: mdia), let stbl = bytes.child("stbl", in: minf) else { return nil }
            return SampleTable(bytes: bytes, stbl: stbl)?.firstKeyFrameEnd()
        }
        return nil
    }

    /// トラックのサンプル（映像では1フレーム）がファイルのどこにあるかの表。
    /// https://developer.apple.com/documentation/quicktime-file-format/sample_table_atom
    private struct SampleTable {
        /// キーフレームの番号（1から）。表がなければ、すべてのサンプルがキーフレーム。
        let syncSamples: [Int]?
        /// すべてのサンプルが同じ大きさなら、その大きさ。
        let uniformSize: Int
        let sizes: [Int]
        /// チャンク（続けて置かれたサンプルのまとまり）ごとの、始まりのチャンクの番号（1から）と、1チャンクあたりのサンプルの数。
        let chunkRuns: [(firstChunk: Int, samplesPerChunk: Int)]
        let chunkOffsets: [Int]

        init?(bytes: Bytes, stbl: Range<Int>) {
            if let stss = bytes.child("stss", in: stbl) {
                guard let entries = bytes.table(in: stss, columns: 1) else { return nil }
                syncSamples = entries.map { $0[0] }
            } else {
                syncSamples = nil
            }
            guard let stsz = bytes.child("stsz", in: stbl),
                  let uniformSize = bytes.uint32(at: stsz.lowerBound + 4),
                  let count = bytes.uint32(at: stsz.lowerBound + 8)
            else { return nil }
            self.uniformSize = uniformSize
            if uniformSize == 0 {
                // 読んだ部分に収まらない数は、壊れた表とみなす。
                guard count <= (stsz.upperBound - stsz.lowerBound - 12) / 4 else { return nil }
                sizes = (0..<count).compactMap { bytes.uint32(at: stsz.lowerBound + 12 + $0 * 4) }
            } else {
                sizes = []
            }
            guard let stsc = bytes.child("stsc", in: stbl), let runs = bytes.table(in: stsc, columns: 3) else { return nil }
            chunkRuns = runs.map { (firstChunk: $0[0], samplesPerChunk: $0[1]) }
            if let stco = bytes.child("stco", in: stbl) {
                guard let offsets = bytes.table(in: stco, columns: 1) else { return nil }
                chunkOffsets = offsets.map { $0[0] }
            } else if let co64 = bytes.child("co64", in: stbl) {
                guard let offsets = bytes.table(in: co64, columns: 1, width: 8) else { return nil }
                chunkOffsets = offsets.map { $0[0] }
            } else {
                return nil
            }
        }

        func firstKeyFrameEnd() -> Int? {
            let sample = syncSamples.map { $0.first } ?? 1
            guard let sample, sample >= 1,
                  let location = chunk(of: sample),
                  location.chunk >= 1, location.chunk <= chunkOffsets.count
            else { return nil }
            var offset = chunkOffsets[location.chunk - 1]
            if uniformSize > 0 {
                guard let skipped = multiply(uniformSize, sample - location.firstSample), let next = add(offset, skipped) else { return nil }
                offset = next
            } else {
                // 大きさの表にないサンプルで止まるため、回る数は表の長さまで。
                for preceding in location.firstSample..<sample {
                    guard let size = size(of: preceding), let next = add(offset, size) else { return nil }
                    offset = next
                }
            }
            guard let size = size(of: sample) else { return nil }
            return add(offset, size)
        }

        private func size(of sample: Int) -> Int? {
            if uniformSize > 0 {
                return uniformSize
            }
            return sizes.indices.contains(sample - 1) ? sizes[sample - 1] : nil
        }

        /// サンプルが入っているチャンクの番号と、そのチャンクの最初のサンプルの番号。
        private func chunk(of sample: Int) -> (chunk: Int, firstSample: Int)? {
            var firstSampleOfRun = 1
            for (index, run) in chunkRuns.enumerated() {
                guard run.samplesPerChunk > 0 else { return nil }
                let nextFirstChunk = index + 1 < chunkRuns.count ? chunkRuns[index + 1].firstChunk : chunkOffsets.count + 1
                guard nextFirstChunk > run.firstChunk else { return nil }
                guard let samplesInRun = multiply(nextFirstChunk - run.firstChunk, run.samplesPerChunk),
                      let nextFirstSample = add(firstSampleOfRun, samplesInRun)
                else { return nil }
                if sample < nextFirstSample {
                    let chunkInRun = (sample - firstSampleOfRun) / run.samplesPerChunk
                    return (run.firstChunk + chunkInRun, firstSampleOfRun + chunkInRun * run.samplesPerChunk)
                }
                firstSampleOfRun = nextFirstSample
            }
            return nil
        }
    }

    // 大きさや位置は、他のサーバーのファイルから読んだ値で信じられないため、桁あふれを確かめて足す。壊れた値ならnil。
    private static func add(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }

    /// MP4の箱（box、QuickTimeではatom）の並びを読む。
    struct Bytes {
        private let storage: [UInt8]

        init(_ storage: [UInt8]) {
            self.storage = storage
        }

        var count: Int { storage.count }

        struct BoxHeader {
            let type: String
            let start: Int
            let headerLength: Int
            /// 箱の終わり。ファイルの終わりまで続く箱（大きさが0）ではnil。
            let end: Int?

            func payload(upTo end: Int) -> Range<Int> { (start + headerLength)..<end }
        }

        /// `offset`から始まる箱の頭。頭が読んだ部分に収まっていない、または大きさが頭より小さければnil。
        func boxHeader(at offset: Int) -> BoxHeader? {
            guard let size32 = uint32(at: offset), let type = string(at: offset + 4, length: 4) else { return nil }
            switch size32 {
            case 0:
                return BoxHeader(type: type, start: offset, headerLength: 8, end: nil)
            case 1:
                guard let size64 = uint64(at: offset + 8), size64 >= 16, let end = add(offset, size64) else { return nil }
                return BoxHeader(type: type, start: offset, headerLength: 16, end: end)
            default:
                guard size32 >= 8 else { return nil }
                return BoxHeader(type: type, start: offset, headerLength: 8, end: offset + size32)
            }
        }

        /// `range`の中に並ぶ箱。はみ出す箱や読めない箱があればnil。
        func children(in range: Range<Int>) -> [(type: String, payload: Range<Int>)]? {
            var result: [(type: String, payload: Range<Int>)] = []
            var offset = range.lowerBound
            while offset < range.upperBound {
                guard let header = boxHeader(at: offset), let end = header.end, end <= range.upperBound else { return nil }
                result.append((header.type, header.payload(upTo: end)))
                offset = end
            }
            return result
        }

        func child(_ type: String, in range: Range<Int>) -> Range<Int>? {
            children(in: range)?.first { $0.type == type }?.payload
        }

        /// 版と印（4バイト）、項目の数（4バイト）に続く表。`width`バイトの数が、1行に`columns`個並ぶ。
        func table(in payload: Range<Int>, columns: Int, width: Int = 4) -> [[Int]]? {
            guard let count = uint32(at: payload.lowerBound + 4) else { return nil }
            let rowLength = columns * width
            guard count <= (payload.upperBound - payload.lowerBound - 8) / rowLength else { return nil }
            var rows: [[Int]] = []
            rows.reserveCapacity(count)
            for row in 0..<count {
                var values: [Int] = []
                for column in 0..<columns {
                    let offset = payload.lowerBound + 8 + row * rowLength + column * width
                    guard let value = width == 8 ? uint64(at: offset) : uint32(at: offset) else { return nil }
                    values.append(value)
                }
                rows.append(values)
            }
            return rows
        }

        func uint32(at offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= storage.count else { return nil }
            return storage[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
        }

        func uint64(at offset: Int) -> Int? {
            guard offset >= 0, offset + 8 <= storage.count, storage[offset] < 0x80 else { return nil }
            return storage[offset..<(offset + 8)].reduce(0) { $0 << 8 | Int($1) }
        }

        func string(at offset: Int, length: Int) -> String? {
            guard offset >= 0, offset + length <= storage.count else { return nil }
            return String(decoding: storage[offset..<(offset + length)], as: UTF8.self)
        }
    }
}
