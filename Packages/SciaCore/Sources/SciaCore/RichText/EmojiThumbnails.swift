import Compression
public import CoreGraphics
public import Foundation
import os
import Synchronization

/// 絵文字のパレットで、静止画が届くまでの間に描く、カスタム絵文字の小さい静止画（docs/animated-custom-emoji.mdの「絵文字ピッカーの小さい静止画」）。
/// 展開済みの画素をLZ4で圧縮して1つのファイルに並べ、メモリに写して（mmap）読む。描くときに、画像の形式の展開もファイルの読み出しも待たないので、
/// CPUが動く絵文字のコマの展開で埋まっていても、どの速さで流しても絵文字の枠が空かない。
/// iPhone 16 Proで約6000個のパレットを流すと、端末に置いた画像から静止画を作るのに、中央で579msかかっていたため。
/// LZ4にしたのは、描くたびにメインスレッドで展開するため。fedibird.comの6129個をMacで測ると、非圧縮の58%の大きさで、1つを1.4µsで展開できた。
/// LZFSEは48%まで小さくなるが展開に7.4µs、zlibは45%で14.5µsかかった。
///
/// 記録の並びは、先頭の`header`のあとに、URLの長さ（4バイト）、URL、幅と高さ（2バイトずつ）、圧縮した画素の長さ（4バイト）、4バイト境界までの詰め物、
/// LZ4で圧縮した画素（RGBA、乗算済み）、4バイト境界までの詰め物。
/// 足すときは末尾に書き足し、同じURLはあとの記録を使う。写したデータは書き足しても伸びないので、足した画像は次に読み込むまでメモリに持つ。
public final class EmojiThumbnails: Sendable {
    private struct Entry: Sendable {
        /// 圧縮した画素の始まりと長さ。
        let offset: Int
        let length: Int
        let width: Int
        let height: Int
    }

    private struct State: Sendable {
        var mapped: Data?
        var entries: [URL: Entry] = [:]
        var added: [URL: CGImage] = [:]
        var isLoaded = false
        /// 静止画がなかったときに求められて、小さい静止画を返した数と、返せなかった数。返せなかった分だけ、パレットの枠が空く。
        var served = 0
        var missed = 0
        /// ファイルの、読めた最後の記録の終わり。書き足す前に、ここまで切り詰める。書きかけで途切れた記録の後ろに書き足すと、
        /// 書き足した記録が途切れた記録の続きとして読まれ、起動し直したときに引けなくなるため。まだ調べていなければnil。`writer`の上でだけ使う。
        var fileEnd: Int?
    }

    /// 書き方を変えたら上げる。読んだファイルの値か高さが違えば、捨てて作り直す。
    static var version: UInt32 { 2 }
    /// 1枚の幅の、高さに対する上限の割合。極端に横長な絵文字で場所を取りすぎないため。静止画の読み方（`ImageDecoder.maxPixelSize(forHeight:of:)`）と同じ。
    static var maxAspectRatio: Double { 8 }

    public let file: URL
    /// 小さい静止画の高さのピクセル数。
    public let pixelHeight: Int
    private let state = Mutex(State())
    /// ファイルに書くのと、画像を縮めるのを、1つずつ行う。
    private let writer = DispatchQueue(label: "net.mizle.scia.emoji-thumbnails", qos: .utility)
    private let logger = SciaLog.logger(category: "emoji")

    public init(file: URL, pixelHeight: Int) {
        self.file = file
        self.pixelHeight = max(pixelHeight, 1)
    }

    /// ファイルを読み込む。2回目からは何もしない。メインスレッドの外で呼ぶ。
    public func load() {
        let needsLoad = state.withLock { state in
            defer { state.isLoaded = true }
            return !state.isLoaded
        }
        guard needsLoad else { return }
        let (mapped, entries) = Self.read(file, pixelHeight: pixelHeight)
        state.withLock { state in
            state.mapped = mapped
            state.entries = entries
        }
    }

    /// `url`の小さい静止画。まだ読み込んでいないか、作っていなければnil。
    public func image(for url: URL) -> CGImage? {
        state.withLock { state -> CGImage? in
            let image = Self.image(for: url, in: state)
            if image == nil {
                state.missed += 1
            } else {
                state.served += 1
            }
            return image
        }
    }

    private static func image(for url: URL, in state: State) -> CGImage? {
        if let image = state.added[url] { return image }
        guard let entry = state.entries[url], let mapped = state.mapped,
              let pixels = decompress(mapped[(mapped.startIndex + entry.offset)..<(mapped.startIndex + entry.offset + entry.length)], count: entry.width * entry.height * 4)
        else { return nil }
        // 1枚は数KBなので、写したデータから展開して画像にする。ページがまだ読まれていなければ、ここで読む。
        return makeImage(pixels, width: entry.width, height: entry.height)
    }

    /// 状態ダンプ。URLは出さず、数だけを書く。
    public func stateDump() -> String {
        state.withLock { state in
            "pixelHeight: \(pixelHeight) stored: \(state.entries.count) added: \(state.added.count) served: \(state.served) missed: \(state.missed)"
        }
    }

    public func contains(_ url: URL) -> Bool {
        state.withLock { $0.added[url] != nil || $0.entries[url] != nil }
    }

    /// 持っている小さい静止画の数。
    public var count: Int {
        state.withLock { state in Set(state.entries.keys).union(state.added.keys).count }
    }

    /// `image`を縮めて、`url`の小さい静止画として足す。持っていれば何もしない。縮めるのと書くのは、裏で行う。
    public func add(_ url: URL, image: CGImage) {
        guard !contains(url) else { return }
        writer.async { [self] in
            guard !contains(url),
                  let (pixels, width, height) = Self.scale(image, toHeight: pixelHeight), let made = Self.makeImage(pixels, width: width, height: height)
            else { return }
            state.withLock { $0.added[url] = made }
            append(url: url, pixels: pixels, width: width, height: height)
        }
    }

    /// `urls`にないものを消して、ファイルを書き直す。絵文字のリストから外れた（画像を差し替えた、消した）絵文字を残し続けないため。
    /// 書き直したファイルは、次に読み込むときから写す。今の起動では、残すものを前のとおり引ける。
    public func prune(keeping urls: Set<URL>) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.async { [self] in
                defer { continuation.resume() }
                let (mapped, entries) = Self.read(file, pixelHeight: pixelHeight)
                let kept = entries.filter { urls.contains($0.key) }
                guard kept.count < entries.count || Self.storedRecordCount(mapped) > entries.count else { return }
                var data = Self.header(pixelHeight: pixelHeight)
                for (url, entry) in kept {
                    guard let mapped else { break }
                    Self.appendRecord(to: &data, url: url, compressed: mapped.subdata(in: entry.offset..<(entry.offset + entry.length)), width: entry.width, height: entry.height)
                }
                do {
                    try data.write(to: file, options: .atomic)
                    let end = data.count
                    state.withLock { state in
                        state.fileEnd = end
                        state.entries = state.entries.filter { urls.contains($0.key) }
                        state.added = state.added.filter { urls.contains($0.key) }
                    }
                    logger.info("emoji thumbnails pruned kept=\(kept.count, privacy: .public) removed=\(entries.count - kept.count, privacy: .public)")
                } catch {
                    logger.error("emoji thumbnails prune failed: \(SciaLog.describe(error), privacy: .public)")
                }
            }
        }
    }

    /// ファイルにある小さい静止画の、URLごとの大きさ（圧縮した画素と、URLや幅と高さの記録）。設定のストレージで、サーバーごとに数えるのに使う。
    /// 同じURLの記録が重なっていれば、あとの記録だけを数える。
    public func storedSizes() -> [URL: Int] {
        Self.read(file, pixelHeight: pixelHeight).entries.reduce(into: [:]) { sizes, item in
            sizes[item.key] = item.value.length + Data(item.key.absoluteString.utf8).count + 12
        }
    }

    /// 書いた分を待つ。テストで、書き終えてから読み直すのに使う。
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.async { continuation.resume() }
        }
    }

    // MARK: - ファイル

    private func append(url: URL, pixels: Data, width: Int, height: Int) {
        do {
            var end = state.withLock { $0.fileEnd } ?? Self.validEnd(of: file, pixelHeight: pixelHeight)
            if end == nil {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let header = Self.header(pixelHeight: pixelHeight)
                try header.write(to: file, options: .atomic)
                end = header.count
            }
            guard let end, let compressed = Self.compress(pixels) else { return }
            var record = Data()
            Self.appendRecord(to: &record, url: url, compressed: compressed, width: width, height: height)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(end))
            try handle.seek(toOffset: UInt64(end))
            try handle.write(contentsOf: record)
            state.withLock { $0.fileEnd = end + record.count }
        } catch {
            // どこまで書けたか分からないので、次に書き足すときに調べ直す。
            state.withLock { $0.fileEnd = nil }
            logger.error("emoji thumbnails write failed: \(SciaLog.describe(error), privacy: .public)")
        }
    }

    /// 読めた最後の記録の終わり。先頭の書き方か高さが違うか、ファイルがなければnil。
    private static func validEnd(of file: URL, pixelHeight: Int) -> Int? {
        let (mapped, _) = read(file, pixelHeight: pixelHeight, headerOnly: true)
        guard let mapped else { return nil }
        return recordsEnd(mapped)
    }

    private static let magic = Data("SCET".utf8)

    private static func header(pixelHeight: Int) -> Data {
        var data = magic
        data.append(contentsOf: withUnsafeBytes(of: version.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(pixelHeight).littleEndian, Array.init))
        return data
    }

    /// 記録を`data`に足す。圧縮した画素が4バイト境界から始まるよう、前に詰め物を入れる。圧縮した長さは4の倍数とは限らないので、
    /// 次の記録も4バイト境界から始まるよう、後ろにも詰め物を入れる。`data`の長さは4の倍数で渡す。
    private static func appendRecord(to data: inout Data, url: URL, compressed: Data, width: Int, height: Int) {
        let name = Data(url.absoluteString.utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(name.count).littleEndian, Array.init))
        data.append(name)
        data.append(contentsOf: withUnsafeBytes(of: UInt16(width).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(height).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(compressed.count).littleEndian, Array.init))
        data.append(Data(count: (4 - data.count % 4) % 4))
        data.append(compressed)
        data.append(Data(count: (4 - compressed.count % 4) % 4))
    }

    /// 画素をLZ4で圧縮する。縮まらない画素は、圧縮できずにnilになる。
    private static func compress(_ pixels: Data) -> Data? {
        var output = Data(count: pixels.count + 64)
        let size = output.withUnsafeMutableBytes { destination in
            pixels.withUnsafeBytes { source in
                guard let to = destination.bindMemory(to: UInt8.self).baseAddress, let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(to, destination.count, from, source.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard size > 0 else { return nil }
        return output.prefix(size)
    }

    /// LZ4で圧縮した画素を、`count`バイトに展開する。長さが合わなければ、壊れているのでnil。
    private static func decompress(_ compressed: Data, count: Int) -> Data? {
        var output = Data(count: count)
        let size = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                guard let to = destination.bindMemory(to: UInt8.self).baseAddress, let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, count, from, source.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return size == count ? output : nil
    }

    /// ファイルを写して、記録を並べる。読めない記録があれば、そこから先は使わない。先頭の書き方か高さが違えば、何も使わない。
    private static func read(_ file: URL, pixelHeight: Int, headerOnly: Bool = false) -> (mapped: Data?, entries: [URL: Entry]) {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count >= 12, data.prefix(4) == magic,
              integer(UInt32.self, in: data, at: 4) == version, integer(UInt32.self, in: data, at: 8) == UInt32(pixelHeight)
        else { return (nil, [:]) }
        guard !headerOnly else { return (data, [:]) }
        var entries: [URL: Entry] = [:]
        for record in records(data) {
            entries[record.url] = record.entry
        }
        return (data, entries)
    }

    /// 書いてある記録の数。同じURLの記録が重なって溜まっているかを見る。
    private static func storedRecordCount(_ data: Data?) -> Int {
        guard let data else { return 0 }
        return records(data).count
    }

    /// 読めた最後の記録の終わり。
    private static func recordsEnd(_ data: Data) -> Int {
        records(data).last?.end ?? 12
    }

    /// 読める記録を、先頭から順に並べる。読めない記録があれば、そこで止める。
    private static func records(_ data: Data) -> [(url: URL, entry: Entry, end: Int)] {
        guard data.count >= 12 else { return [] }
        var records: [(url: URL, entry: Entry, end: Int)] = []
        var offset = 12
        while offset + 4 <= data.count {
            let length = Int(integer(UInt32.self, in: data, at: offset))
            let nameEnd = offset + 4 + length
            guard nameEnd <= data.count, let string = String(data: data[(data.startIndex + offset + 4)..<(data.startIndex + nameEnd)], encoding: .utf8), let url = URL(string: string) else { break }
            guard nameEnd + 8 <= data.count else { break }
            let width = Int(integer(UInt16.self, in: data, at: nameEnd))
            let height = Int(integer(UInt16.self, in: data, at: nameEnd + 2))
            let compressedLength = Int(integer(UInt32.self, in: data, at: nameEnd + 4))
            let start = nameEnd + 8 + (4 - (nameEnd + 8) % 4) % 4
            let end = start + compressedLength
            let padded = end + (4 - compressedLength % 4) % 4
            guard width > 0, height > 0, compressedLength > 0, padded <= data.count else { break }
            records.append((url, Entry(offset: start, length: compressedLength, width: width, height: height), padded))
            offset = padded
        }
        return records
    }

    private static func integer<T: FixedWidthInteger>(_: T.Type, in data: Data, at offset: Int) -> T {
        var value = T.zero
        _ = withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer, from: (data.startIndex + offset)..<(data.startIndex + offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    // MARK: - 画素

    private static var colorSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.sRGB) }
    private static var bitmapInfo: UInt32 { CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue }

    /// 高さを`height`にそろえて縮めた画素。幅は縦横の比で決め、高さの`maxAspectRatio`倍で止める。
    /// 幅で止めるときは、縦横の比を保つよう、高さも縮める。
    private static func scale(_ image: CGImage, toHeight targetHeight: Int) -> (Data, Int, Int)? {
        guard image.width > 0, image.height > 0, let colorSpace else { return nil }
        let ratio = Double(image.width) / Double(image.height)
        let width = max(1, Int((Double(targetHeight) * min(ratio, maxAspectRatio)).rounded()))
        let height = ratio > maxAspectRatio ? max(1, Int((Double(width) / ratio).rounded())) : targetHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else { return nil }
        return (Data(bytes: bytes, count: width * height * 4), width, height)
    }

    private static func makeImage(_ pixels: Data, width: Int, height: Int) -> CGImage? {
        guard let colorSpace, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
