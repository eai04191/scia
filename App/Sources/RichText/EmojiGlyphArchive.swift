import os
import SciaCore
import Synchronization
import UIKit

/// 絵文字ピッカーのUnicodeの絵文字の画像を、端末に置いて持つ（docs/animated-custom-emoji.mdの「Unicodeの絵文字の画像」）。
/// メモリに持つ画像（`EmojiGlyphImageStore`）は、作るのが非同期で、上限の16MBに約1900個のうち856個しか入らないため、
/// 速く流すとメモリにない絵文字の枠が、最初のフレームで空いていた（SE3で6000pt/秒のとき約14%）。
///
/// - 小さい画像は、空き容量にかかわらず持つ。最初のフレームから粗い絵が出て、枠は空かない
/// - 描く大きさの画像は、必須でない用途の空きが足りるときだけ持つ。持てる端末では、最初から鮮明な絵が出る
///
/// 形式は、カスタム絵文字の小さい静止画（`EmojiThumbnails`）と同じく、LZ4で圧縮して1つのファイルに並べ、メモリに写して読む。
/// 置き場所は、描く大きさと絵ごとのフォルダー。絵文字は`scia-glyph:`のURLで引く。文字として描かれる絵文字（twemojiの「©」など）は、外観で色が変わるので、形だけで持ち（`scia-glyph-shape:`）、
/// 描くときに今の外観の文字の色を付ける。外観が変わるたびに全部を作り直すと、SE3で約7〜8秒のCPUの時間がかかるため。
final class EmojiGlyphArchive: Sendable {
    /// 描く大きさと絵。変わったら作り直す。
    struct Geometry: Codable, Hashable, Sendable {
        var pointSize: CGFloat
        var width: CGFloat
        var height: CGFloat
        var scale: CGFloat
        var style: EmojiStyle
        /// iOSの版。版が変わると絵が変わる。
        var systemVersion: String

        var pixelHeight: Int { Int((height * scale).rounded()) }
    }

    /// 端末に置いた画像。`isShape`なら形だけなので、描くときに文字の色を付ける。
    struct Glyph {
        let image: CGImage
        let isShape: Bool
        /// 描く大きさの画像か。小さい画像なら、メモリに描く大きさの画像を作らせる。
        let isFull: Bool
    }

    private struct Files: Sendable {
        let geometry: Geometry
        let small: EmojiThumbnails
        let full: EmojiThumbnails
    }

    /// 小さい画像の高さのピクセル数。カスタム絵文字の小さい静止画と同じ。
    static let smallPixelHeight = 32
    /// 描く大きさの画像を作り始める前と、作った量が増えるたびに、必須でない用途の空きを読み直す間隔（バイト）。カスタム絵文字の先読みと同じ。
    static let capacityCheckInterval = 10 * 1_024 * 1_024

    let directory: URL
    private let availableCapacity: @Sendable () -> Int?
    private let files = Mutex<Files?>(nil)
    private let logger = SciaLog.logger(category: "emoji")

    init(directory: URL, availableCapacity: @escaping @Sendable () -> Int? = EmojiImageFiles.opportunisticCapacity) {
        self.directory = directory
        self.availableCapacity = availableCapacity
    }

    private var geometryFile: URL { directory.appending(path: "geometry.json") }

    /// 絵文字ピッカーで描く大きさと絵を渡す。前に作ったときと違えば、前の画像を消して作り直す。
    /// 起動したあと、絵文字ピッカーを開く前は、前に渡した大きさと絵で読む（`loadStoredGeometry()`）。
    func use(_ geometry: Geometry) {
        let current = files.withLock { $0?.geometry }
        guard current != geometry else { return }
        let stored = (try? Data(contentsOf: geometryFile)).flatMap { try? JSONDecoder().decode(Geometry.self, from: $0) }
        if stored != geometry {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(geometry).write(to: geometryFile, options: .atomic)
            } catch {
                logger.error("emoji glyph archive geometry write failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
        open(geometry)
        removeFolders(except: geometry)
    }

    /// 前に絵文字ピッカーで渡した大きさと絵で、置いた画像を読めるようにする。iOSの版か絵文字の絵の設定が変わっていれば、読まない。
    func loadStoredGeometry(style: EmojiStyle) {
        guard files.withLock({ $0 == nil }),
              let stored = (try? Data(contentsOf: geometryFile)).flatMap({ try? JSONDecoder().decode(Geometry.self, from: $0) }),
              stored.style == style, stored.systemVersion == Self.systemVersion
        else { return }
        open(stored)
    }

    /// 大きさと絵ごとに、画像を置くフォルダーを分ける。切り替える前に作り始めた画像を書き終える前に、前のフォルダーを消しても、
    /// 新しいフォルダーのファイルに混ざらないため。
    private func folder(for geometry: Geometry) -> URL {
        let name = "\(geometry.style.rawValue)-\(geometry.systemVersion)-\(Int((geometry.width * geometry.scale).rounded()))x\(geometry.pixelHeight)-\(Int((geometry.pointSize * 100).rounded()))"
        return directory.appending(fileName: SafeFileName(name), directoryHint: .isDirectory)
    }

    /// 今の大きさと絵のほかのフォルダーを消す。切り替える前に作り始めた画像が、消したあとにフォルダーを作り直して書いても、次に切り替えたときに消える。
    private func removeFolders(except geometry: Geometry) {
        let kept = folder(for: geometry).lastPathComponent
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders where folder.lastPathComponent != kept && (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func open(_ geometry: Geometry) {
        let folder = folder(for: geometry)
        let opened = Files(
            geometry: geometry,
            small: EmojiThumbnails(file: folder.appending(path: "small.bin"), pixelHeight: Self.smallPixelHeight),
            full: EmojiThumbnails(file: folder.appending(path: "full.bin"), pixelHeight: geometry.pixelHeight)
        )
        opened.small.load()
        opened.full.load()
        files.withLock { $0 = opened }
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// `text`の画像。描く大きさの画像があればそれを、なければ小さい画像を返す。どちらもなければnil。
    /// `geometry`が今の大きさと絵と違えば、使わない。
    func glyph(for text: String, geometry: Geometry) -> Glyph? {
        guard let files = files.withLock({ $0 }), files.geometry == geometry else { return nil }
        for isShape in [false, true] {
            let url = Self.url(text, isShape: isShape)
            if let image = files.full.image(for: url) {
                return Glyph(image: image, isShape: isShape, isFull: true)
            }
            if let image = files.small.image(for: url) {
                return Glyph(image: image, isShape: isShape, isFull: false)
            }
        }
        return nil
    }

    static func url(_ text: String, isShape: Bool) -> URL {
        var components = URLComponents()
        components.scheme = isShape ? "scia-glyph-shape" : "scia-glyph"
        components.path = text
        // 絵文字はどれもパーセントエンコードすればURLのパスになる。
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// まだ持っていない絵文字の画像を作る。絵文字ピッカーを開いていない間に、裏で呼ぶ。止められたら（`Task.isCancelled`）、途中で終える。
    /// 小さい画像は全部作る。描く大きさの画像は、必須でない用途の空きが、残りの見積もり以上あるときだけ作る。
    func build(_ texts: [String]) async {
        guard let files = files.withLock({ $0 }) else { return }
        let missing = texts.filter { text in
            ![false, true].contains { files.small.contains(Self.url(text, isShape: $0)) && files.full.contains(Self.url(text, isShape: $0)) }
        }
        guard !missing.isEmpty else { return }
        // 見積もりは非圧縮の大きさで、圧縮すると小さくなるので、少なめに作ることはあっても、空きを超えて作ることはない。
        let fullBytes = Int(files.geometry.width * files.geometry.scale) * files.geometry.pixelHeight * 4
        var keepsFull = (availableCapacity() ?? 0) >= missing.count * fullBytes
        var writtenSinceCheck = 0
        var made = 0
        for (index, text) in missing.enumerated() {
            guard !Task.isCancelled else { break }
            if keepsFull, writtenSinceCheck >= Self.capacityCheckInterval {
                keepsFull = (availableCapacity() ?? 0) >= (missing.count - index) * fullBytes
                writtenSinceCheck = 0
            }
            let hasSmall = [false, true].contains { files.small.contains(Self.url(text, isShape: $0)) }
            guard !hasSmall || keepsFull else { continue }
            guard let (image, isShape) = await Self.render(text, geometry: files.geometry) else { continue }
            // 作っている間に大きさか絵が変わったら、前の大きさの画像を足さずにやめる。
            guard !Task.isCancelled, self.files.withLock({ $0?.geometry }) == files.geometry else { break }
            let url = Self.url(text, isShape: isShape)
            files.small.add(url, image: image)
            if keepsFull {
                files.full.add(url, image: image)
                writtenSinceCheck += fullBytes
            }
            made += 1
        }
        logger.info("emoji glyphs built made=\(made, privacy: .public) keepsFull=\(keepsFull, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
    }

    /// ライトの外観の文字の色（黒）で描き、色の付いた画素がなければ、形だけの絵文字とする。
    @concurrent
    private static func render(_ text: String, geometry: Geometry) async -> (CGImage, isShape: Bool)? {
        let request = EmojiGlyphImageStore.Request(
            text: text, pointSize: geometry.pointSize, style: geometry.style, width: geometry.width, height: geometry.height, scale: geometry.scale, userInterfaceStyle: .light
        )
        guard let image = await EmojiGlyphImageStore.draw(request).cgImage else { return nil }
        return (image, isShape(image))
    }

    /// 透明でない画素がどれも黒（乗算済みのRGBが0）なら、1色だけの形。
    static func isShape(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var hasInk = false
        for offset in stride(from: 0, to: width * height * 4, by: 4) where pixels[offset + 3] > 0 {
            hasInk = true
            if pixels[offset] > 8 || pixels[offset + 1] > 8 || pixels[offset + 2] > 8 {
                return false
            }
        }
        return hasInk
    }

    /// 書いている分を待つ。テストで、書き終えてから読み直すのに使う。
    func flush() async {
        guard let files = files.withLock({ $0 }) else { return }
        await files.small.flush()
        await files.full.flush()
    }

    /// 置いた画像の大きさ。設定のストレージの「Unicodeの絵文字」に数える。
    func storedBytes() -> Int64 {
        StorageUsage.allocatedSize(of: directory)
    }

    /// 状態ダンプ。絵文字は出さず、数だけを書く。
    func stateDump() -> String {
        guard let files = files.withLock({ $0 }) else { return "geometry: none" }
        return "pixelHeight: \(files.geometry.pixelHeight) small: \(files.small.stateDump())\nfull: \(files.full.stateDump())"
    }
}
