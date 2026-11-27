public import CoreGraphics
public import Foundation
import ImageIO
import Synchronization

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
        return maxPixelSize(forHeight: height, width: width, height: sourceHeight, maxAspectRatio: maxAspectRatio)
    }

    /// 描く向きに直した大きさが`width`×`sourceHeight`の画像の、高さを`height`ピクセルにそろえて縮めるときの、長い辺の上限。
    public static func maxPixelSize(forHeight height: Int, width: Int, height sourceHeight: Int, maxAspectRatio: Double = 8) -> Int {
        let aspectRatio = min(max(Double(width) / Double(sourceHeight), 1), maxAspectRatio)
        return Int((Double(height) * aspectRatio).rounded(.up))
    }

    public static func thumbnail(ofFile url: URL, maxPixelSize: Int, dynamicRange: DynamicRange) async -> CGImage? {
        await run { CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { thumbnail(of: $0, maxPixelSize: maxPixelSize, dynamicRange: dynamicRange) } }
    }

    /// ImageIOで画像を展開する`body`を、専用のシリアルキューで走らせる。
    /// 同時に走らせるのは、協調スレッドで展開していたときの同時数（協調スレッドの数と同じCPUのコア数）までにし、展開に使うメモリの最大を前と変えない。
    /// `body`は呼んだタスクの優先度で走る。待っている間に取り消されても、展開は止めない。
    /// - Parameter work: 展開の種類。動く画像のコマは、1枚の画像を待たせない（`DecodeWork`）。
    static func run<T: Sendable>(_ work: DecodeWork = .image, _ body: @escaping @Sendable () -> T) async -> T {
        let qos = DispatchQoS(qosClass: DispatchQoS.QoSClass(rawValue: qos_class_t(rawValue: UInt32(Task.currentPriority.rawValue))) ?? .default, relativePriority: 0)
        return await queues.run(work, qos: qos, body)
    }

    private static let queues = DecodeQueues(count: ProcessInfo.processInfo.activeProcessorCount)

    /// 展開のキューごとの、待っているか走っている展開の数。待ちが固まったテストで、展開が詰まっているかを見る。
    static func queueState() -> String {
        queues.state()
    }
}

/// 展開の種類。
enum DecodeWork: Sendable {
    /// 1枚の画像。空いた枠を埋める画像で、縮めて読むので短く済む。
    case image
    /// 動く画像のコマ。全部のコマを展開するので長くかかり、届くまでは1枚の画像で描けている。
    case frames
}

/// 展開に使うシリアルキュー。展開を順番待ちの列に並べ、空いたキューが列から取って走らせる。1枚の画像を、動く画像のコマの後ろで待たせない。
///
/// 空いたキューは、1枚の画像を、動く画像のコマより先に取る。キューの前半は1枚の画像だけを取り、コマは後半のキューだけが取る。
/// iPhone 16 Proで絵文字のパレット（約6000個、うち動くもの約1100個）を流すと、1枚の展開そのものは中央0.9msなのに、
/// 動く絵文字のコマと同じキューを分け合って、キューを待つ時間の中央が670msあり、絵文字の枠が空いたまま見えていたため。
///
/// 入れるキューを先に決めない。決めてしまうと、決めた先で長い展開（大きな写真、コマ）が走っているあいだ、ほかのキューが空いても待つため。
/// キューは協調スレッドで貸し借りしない。返すたびと借りるたびに協調スレッドの順番を待ち、同じ端末で、協調スレッドに移るのに中央3ms、
/// 遅いほうの1割で22msかかっていて、キューの半分を1枚の画像に残しても、キューを待つ時間の中央が391msあった。
final class DecodeQueues: Sendable {
    private struct Job {
        let qos: DispatchQoS
        let body: @Sendable () -> Void
    }

    private struct State {
        var images: [Job] = []
        var frames: [Job] = []
        /// キューごとに、展開を走らせているか。
        var busy: [Bool]
    }

    private let queues: [DispatchQueue]
    private let shared: Mutex<State>
    /// コマを取るキューの、最初の位置。それより前は、1枚の画像だけを取る。キューが1本しかなければ0で、分けない。
    private let framesStart: Int

    init(count: Int) {
        let count = max(count, 1)
        queues = (0..<count).map { DispatchQueue(label: "net.mizle.scia.image-decode.\($0)") }
        shared = Mutex(State(busy: Array(repeating: false, count: count)))
        framesStart = count / 2
    }

    func run<T: Sendable>(_ work: DecodeWork, qos: DispatchQoS, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let job = Job(qos: qos) { continuation.resume(returning: body()) }
            let started: (Int, Job)? = shared.withLock { state in
                switch work {
                case .image:
                    state.images.append(job)
                case .frames:
                    state.frames.append(job)
                }
                // 空いたキューのうち、今並べた展開を取れるものを走らせる。取れるのが前に並んだ展開なら、そちらを走らせる。
                for index in state.busy.indices where !state.busy[index] {
                    if let next = Self.take(for: index, framesStart: framesStart, from: &state) {
                        state.busy[index] = true
                        return (index, next)
                    }
                }
                return nil
            }
            if let (index, next) = started {
                start(next, on: index)
            }
        }
    }

    /// `index`のキューが次に取る展開。1枚の画像を先に取り、コマは後半のキューだけが取る。
    private static func take(for index: Int, framesStart: Int, from state: inout State) -> Job? {
        if !state.images.isEmpty {
            return state.images.removeFirst()
        }
        if index >= framesStart, !state.frames.isEmpty {
            return state.frames.removeFirst()
        }
        return nil
    }

    /// `job`を`index`のキューで走らせ、終えたら列から次を取る。取るものがなければ、キューを空いたことにする。
    /// `index`のキューは、走らせている間は走っていることにしてあるので、ほかから処理を入れられない。
    private func start(_ job: Job, on index: Int) {
        queues[index].async(qos: job.qos, flags: .enforceQoS) { [self] in
            job.body()
            let next: Job? = shared.withLock { state in
                let next = Self.take(for: index, framesStart: framesStart, from: &state)
                state.busy[index] = next != nil
                return next
            }
            if let next {
                start(next, on: index)
            }
        }
    }

    func state() -> String {
        shared.withLock { state in
            "decodeQueues busy: \(state.busy.filter(\.self).count) waiting images: \(state.images.count) frames: \(state.frames.count)"
        }
    }
}
