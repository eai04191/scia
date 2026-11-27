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
/// 形式は、カスタム絵文字のサムネイル（`EmojiThumbnails`）と同じく、LZ4で圧縮して1つのファイルに並べ、メモリにマップして読む。
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

    /// 小さい画像の高さのピクセル数。カスタム絵文字のサムネイルと同じ。
    static let smallPixelHeight = 32
    /// 描く大きさの画像を作り始める前と、作った量が増えるたびに、必須でない用途の空きを読み取る間隔（バイト）。カスタム絵文字のプリフェッチと同じ。
    static let capacityCheckInterval = 10 * 1_024 * 1_024

    let directory: URL
    private let availableCapacity: @Sendable () -> Int?
    private let files = Mutex<Files?>(nil)
    /// 切り替え（`use`、`loadStoredGeometry`）を1つずつ行う。並べて行うと、同じファイルを書く`EmojiThumbnails`が2つでき、
    /// それぞれが書き足す位置を持って、相手の記録を切り詰めて消すため。
    private let switching = Mutex<[Geometry: Files]>([:])
    /// この起動で開いた大きさと絵ごとのファイル。画像を引くときに読む。`switching`は開くあいだ握るので、描くたびに待たないよう別に持つ。
    private let openedFiles = Mutex<[Geometry: Files]>([:])
    private let logger = SciaLog.logger(category: "emoji")
    /// どれかのプリセットが使う絵文字の種類。切り替えても、この種類の今のiOSの版のフォルダーは消さない。
    /// プリセットを切り替えるたびに、消した画像を作り直さないため（docs/preset.md）。
    private let keptStyles = Mutex<Set<EmojiStyle>>([])

    init(directory: URL, availableCapacity: @escaping @Sendable () -> Int? = EmojiImageFiles.opportunisticCapacity) {
        self.directory = directory
        self.availableCapacity = availableCapacity
    }

    private var geometryFile: URL { directory.appending(path: "geometry.json") }

    /// 消さずに残す絵文字の種類を渡す。減ったら、その場で、残さなくなった種類のフォルダーを消す。
    /// 同じ大きさと絵のまま使い続けると、`use`で消す契機が来ないため。
    func keep(styles: Set<EmojiStyle>) {
        let previous = keptStyles.withLock { kept in
            defer { kept = styles }
            return kept
        }
        guard !previous.isSubset(of: styles) else { return }
        switching.withLock { opened in
            removeFolders(except: Set(opened.keys))
        }
    }

    /// 絵文字ピッカーで描く大きさと絵を渡す。前に作ったときと違えば、前の画像を消して作り直す。
    /// 起動したあと、絵文字ピッカーを開く前は、前に渡した大きさと絵で読む（`loadStoredGeometry()`）。
    func use(_ geometry: Geometry) {
        guard files.withLock({ $0?.geometry }) != geometry else { return }
        switching.withLock { opened in
            guard files.withLock({ $0?.geometry }) != geometry else { return }
            let stored = storedGeometry()
            if stored != geometry {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(geometry).write(to: geometryFile, options: .atomic)
                } catch {
                    logger.error("emoji glyph archive geometry write failed: \(SciaLog.describe(error), privacy: .public)")
                }
            }
            open(geometry, opened: &opened)
            removeFolders(except: Set(opened.keys))
        }
    }

    /// 前に絵文字ピッカーで渡した大きさと絵で、置いた画像を読めるようにする。読めるようにしたか、もう読めるようになっていればtrue。
    /// iOSの版か絵文字の絵の設定が変わっていれば、読まずにfalse。
    /// 裏で作る側は、これがfalseのときだけ、自分で計算した大きさを渡す。絵文字ピッカーが渡した大きさを優先するため。
    /// 画面の倍率の違う画面にシーンが複数あると、計算した大きさが絵文字ピッカーのものと食い違い、互いの画像を消し合うため。
    @discardableResult
    func loadStoredGeometry(style: EmojiStyle) -> Bool {
        switching.withLock { opened in
            if let current = files.withLock({ $0?.geometry }) {
                return current.style == style && current.systemVersion == Self.systemVersion
            }
            guard let stored = storedGeometry(), stored.style == style, stored.systemVersion == Self.systemVersion else { return false }
            open(stored, opened: &opened)
            return true
        }
    }

    /// 前に絵文字ピッカーで渡した大きさで、絵を`style`にしたもの。iOSの版が変わっていればnil。
    /// アカウントのプリセットの絵の画像を作るときに、大きさを絵文字ピッカーに揃えるのに使う。
    func recordedGeometry(style: EmojiStyle) -> Geometry? {
        guard var stored = storedGeometry(), stored.systemVersion == Self.systemVersion else { return nil }
        stored.style = style
        return stored
    }

    private func storedGeometry() -> Geometry? {
        (try? Data(contentsOf: geometryFile)).flatMap { try? JSONDecoder().decode(Geometry.self, from: $0) }
    }

    /// 大きさと絵ごとに、画像を置くフォルダーを分ける。切り替える前に作り始めた画像を書き終える前に、前のフォルダーを消しても、
    /// 新しいフォルダーのファイルに混ざらないため。
    private func folder(for geometry: Geometry) -> URL {
        let name = "\(geometry.style.rawValue)-\(geometry.systemVersion)-\(Int((geometry.width * geometry.scale).rounded()))x\(geometry.pixelHeight)-\(Int((geometry.pointSize * 100).rounded()))"
        return directory.appending(fileName: SafeFileName(name), directoryHint: .isDirectory)
    }

    /// この起動のうちに開いた大きさと絵のほかのフォルダーを消す。開いたものは、書き手（`EmojiThumbnails`）を使い回すので、
    /// 消すと、戻ったときに書いたつもりの画像がファイルに残らず、次の起動で作り直すまで枠が空くため。次に起動して切り替えたときに消える。
    /// どれかのプリセットが使う種類で、今のiOSの版のフォルダーも消さない。
    private func removeFolders(except geometries: Set<Geometry>) {
        let kept = Set(geometries.map { folder(for: $0).lastPathComponent })
        let keptPrefixes = keptStyles.withLock { $0 }.map { "\($0.rawValue)-\(Self.systemVersion)-" }
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders where !kept.contains(folder.lastPathComponent) && !keptPrefixes.contains(where: folder.lastPathComponent.hasPrefix)
            && (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// 今の大きさと絵を変えずに、`geometry`のファイルを開く。アカウントのプリセットの絵の画像を、裏で作るときに使う。
    /// 今の大きさと絵と、絵文字ピッカーが記録した大きさは、絵文字ピッカーのものを残す。
    func prepare(_ geometry: Geometry) {
        switching.withLock { opened in
            open(geometry, opened: &opened, makesCurrent: false)
        }
    }

    /// 同じ大きさと絵のファイルは、前に開いたものを使い回す。書き手（`EmojiThumbnails`の書く順番）を1つにするため。
    private func open(_ geometry: Geometry, opened: inout [Geometry: Files], makesCurrent: Bool = true) {
        if let reused = opened[geometry] {
            if makesCurrent {
                files.withLock { $0 = reused }
            }
            return
        }
        let folder = folder(for: geometry)
        let made = Files(
            geometry: geometry,
            small: EmojiThumbnails(file: folder.appending(path: "small.bin"), pixelHeight: Self.smallPixelHeight),
            full: EmojiThumbnails(file: folder.appending(path: "full.bin"), pixelHeight: geometry.pixelHeight)
        )
        made.small.load()
        made.full.load()
        opened[geometry] = made
        openedFiles.withLock { $0[geometry] = made }
        if makesCurrent {
            files.withLock { $0 = made }
        }
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// `text`の画像。描く大きさの画像があればそれを、なければ小さい画像を返す。どちらもなければnil。
    /// `geometry`が今の大きさと絵でなく、どのプリセットも使わない絵なら、使わない。
    /// プリセットの使う絵の画像は、ウィンドウごとにアカウントの絵が違うときも使えるよう、今の大きさと絵でなくても返す（docs/preset.md）。
    func glyph(for text: String, geometry: Geometry) -> Glyph? {
        let isCurrent = files.withLock { $0?.geometry } == geometry
        guard isCurrent || keptStyles.withLock({ $0.contains(geometry.style) }),
              let files = openedFiles.withLock({ $0[geometry] })
        else { return nil }
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

    /// まだ持っていない絵文字の画像を作る。止められたら（`Task.isCancelled`）、途中で終える。
    /// 小さい画像は全部作る。描く大きさの画像は、`includesFull`で、必須でない用途の空きが残りの見積もり以上あるときだけ作る。
    /// - Parameter includesFull: falseなら小さい画像だけを、小さく描いて作る。絵文字ピッカーを開いている間に呼ぶ。
    ///   描く大きさで描いてから縮めるより軽く、絵文字ピッカーの画像の読み込みと取り合うCPUを減らすため。
    /// - Parameter geometry: 作る大きさと絵。開いたもののどれか。nilなら今の大きさと絵。
    func build(_ texts: [String], includesFull: Bool = true, geometry: Geometry? = nil) async {
        let target = geometry.flatMap { geometry in openedFiles.withLock { $0[geometry] } } ?? files.withLock { $0 }
        guard let files = target else { return }
        let missing = texts.filter { text in
            ![false, true].contains { files.small.contains(Self.url(text, isShape: $0)) && (!includesFull || files.full.contains(Self.url(text, isShape: $0))) }
        }
        guard !missing.isEmpty else { return }
        // 見積もりは非圧縮の大きさで、圧縮すると小さくなるので、少なめに作ることはあっても、空きを超えて作ることはない。
        let fullBytes = Int(files.geometry.width * files.geometry.scale) * files.geometry.pixelHeight * 4
        var keepsFull = includesFull && (availableCapacity() ?? 0) >= missing.count * fullBytes
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
            var drawn = files.geometry
            if !keepsFull {
                // 小さい画像だけを作るときは、小さい画像の高さで描く。
                drawn.scale = CGFloat(Self.smallPixelHeight) / drawn.height
            }
            guard let (image, isShape) = await Self.render(text, geometry: drawn) else { continue }
            // 作っている間に大きさか絵が変わり、作っている絵をどのプリセットも使わなくなったら、前の大きさの画像を足さずにやめる。
            guard !Task.isCancelled,
                  self.files.withLock({ $0?.geometry }) == files.geometry || keptStyles.withLock({ $0.contains(files.geometry.style) })
            else { break }
            let url = Self.url(text, isShape: isShape)
            files.small.add(url, image: image)
            if keepsFull {
                files.full.add(url, image: image)
                writtenSinceCheck += fullBytes
            }
            made += 1
        }
        logger.info("emoji glyphs built made=\(made, privacy: .public) includesFull=\(includesFull, privacy: .public) keepsFull=\(keepsFull, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
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

    /// 書いている分を待つ。テストで、書き終えてから再読み込みするのに使う。
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
