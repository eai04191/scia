public import CoreGraphics
public import Foundation
import ImageIO

/// 画像を、描く大きさまで縮めて展開する。アイコン、添付ファイル、絵文字、投稿欄の手元のファイル、プロフィール画像の切り抜き、送る前の書き出し直しで、同じ読み方をする。
/// 元の大きさのまま展開すると、大きな写真では時間がかかりメモリも食うため、ImageIOの縮めて読む関数で、長い辺が`maxPixelSize`以下になるように読む。
/// 向きは画素に反映し、描くときに展開し直さないよう、ここで展開しておく。
///
/// 展開は、Swift Concurrencyの協調スレッドやGCDのグローバルキューではなく、`run`の専用のシリアルキューで行う。
/// AV1をハードウェアで読めない端末（シミュレーター、A17 ProとM3より前のチップ）では、AVIFをソフトウェアのデコーダー（AV1SW）が読む。
/// シミュレーターで協調スレッドからAVIFを64枚同時に読むと、協調スレッド10本がすべてAV1SWの中の`pthread_cond_wait`で待ったまま、10分以上進まなかった。
/// AV1SWの仕事をしているスレッドはなく、仕事を待つGCDのスレッドが空いていた。AV1SWは`dispatch_get_global_queue`と`dispatch_group_async`を使うので、
/// グローバルキューに渡した仕事を待っていて、その仕事にスレッドが割り当てられないのだと推測している。
/// グローバルキューから読んでも同じく止まり、1枚ずつ別のシリアルキューから読むと、64枚を同時に読んでも1.4秒で終わった。
///
/// `AnimatedImage`と違って、元の大きさの上限は設けない。縮めて読む関数は原寸で展開しないため。
/// 16000×16000ピクセル（原寸で展開すると約1GB）の単色の画像を、MacのImageIOで長い辺96ピクセルに縮めて読んだときの最大メモリは、
/// PNGで32MB、JPEGで50MB、HEICで21MBだった。GIFは読まずにnilを返した。実機では測っていない。
/// `AnimatedImage`はコマを前のコマと重ねるために原寸で展開するので、上限が要る。
public enum ImageDecoder {
    public enum DynamicRange: Sendable {
        /// HDRの画像はゲインマップを使ってHDRのまま展開する。指定しないとSDRに展開され、HDRで描く設定にしても明るくならない。
        /// どれくらいの明るさで描くかは、画面ごとのtraitで決める。
        case high
        /// SDRで展開する。書き出し直して送る画像に使う。
        case standard
    }

    /// `source`の`index`番目のコマを縮めて展開する。読めなければnil。`run`の中で呼ぶ。
    static func thumbnail(of source: CGImageSource, at index: Int = 0, maxPixelSize: Int, dynamicRange: DynamicRange) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if dynamicRange == .high {
            options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        }
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    public static func thumbnail(of data: Data, maxPixelSize: Int, dynamicRange: DynamicRange) async -> CGImage? {
        await run { CGImageSourceCreateWithData(data as CFData, nil).flatMap { thumbnail(of: $0, maxPixelSize: maxPixelSize, dynamicRange: dynamicRange) } }
    }

    /// 高さを`height`ピクセルにそろえて縮めるときの、長い辺の上限（`maxPixelSize`に渡す値）。行の高さに合わせて描く絵文字に使う。
    /// 長い辺で縮めると、横長の画像は高さが足りずにぼけるため、高さで決める。極端に横長な画像でメモリを使いすぎないよう、幅は高さの`maxAspectRatio`倍で止める。
    /// 大きさを読めなければ`height`を返す。
    public static func maxPixelSize(forHeight height: Int, of data: Data, maxAspectRatio: Double = 8) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, sourceHeight > 0
        else { return height }
        // 5から8の向きは90°回すので、描くときの縦横が入れ替わる。
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            swap(&width, &sourceHeight)
        }
        let aspectRatio = min(max(Double(width) / Double(sourceHeight), 1), maxAspectRatio)
        return Int((Double(height) * aspectRatio).rounded(.up))
    }

    public static func thumbnail(ofFile url: URL, maxPixelSize: Int, dynamicRange: DynamicRange) async -> CGImage? {
        await run { CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { thumbnail(of: $0, maxPixelSize: maxPixelSize, dynamicRange: dynamicRange) } }
    }

    /// ImageIOで画像を展開する`body`を、専用のシリアルキューで走らせる。
    /// 同時に走らせるのは、協調スレッドで展開していたときの同時数（協調スレッドの数と同じCPUのコア数）までにし、展開に使うメモリの最大を前と変えない。
    /// `body`は呼んだタスクの優先度で走る。待っている間に取り消されても、展開は止めない。
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let queue = await queues.take()
        let qos = DispatchQoS(qosClass: DispatchQoS.QoSClass(rawValue: qos_class_t(rawValue: UInt32(Task.currentPriority.rawValue))) ?? .default, relativePriority: 0)
        let result = await withCheckedContinuation { continuation in
            queue.async(qos: qos, flags: .enforceQoS) { continuation.resume(returning: body()) }
        }
        await queues.put(queue)
        return result
    }

    private static let queues = DecodeQueues(count: ProcessInfo.processInfo.activeProcessorCount)

    /// 展開のキューの空きと順番待ちの数。待ちが固まったテストで、展開が詰まっているかを見る。
    static func queueState() async -> String {
        await queues.state()
    }
}

/// 展開に使うシリアルキュー。空いているキューを貸し、空いていなければ返されるまで待たせる。
private actor DecodeQueues {
    private var idle: [DispatchQueue]
    private var waiting: [CheckedContinuation<DispatchQueue, Never>] = []

    init(count: Int) {
        idle = (0..<max(count, 1)).map { DispatchQueue(label: "net.mizle.scia.image-decode.\($0)") }
    }

    func take() async -> DispatchQueue {
        if let queue = idle.popLast() {
            return queue
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func state() -> String {
        "decodeQueues idle: \(idle.count) waiting: \(waiting.count)"
    }

    func put(_ queue: DispatchQueue) {
        if waiting.isEmpty {
            idle.append(queue)
        } else {
            waiting.removeFirst().resume(returning: queue)
        }
    }
}
