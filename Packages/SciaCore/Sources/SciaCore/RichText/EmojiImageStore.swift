import CoreGraphics
public import Foundation
import ImageIO
import MemoryCache
import os

/// カスタム絵文字の画像を読み込み、メモリに持つ。`Image`は描く側の画像の型で、iOSでは`UIImage`にする。
/// 静止画もアニメーション版も、高さを`pixelHeight`にそろえて縮めて持ち、上限を設けて、あふれたら古いものから捨て、また要るときに読み直す。
/// 絵文字だけの本文のように`pixelHeight`より大きく描くときは、描く側が要る高さを渡し、そのURLだけをその高さで読み直して置き換える。
/// 同じURLを大きさごとに別に持たず、1つのURLには、それまでに描いた一番大きい高さの画像を1つだけ持つ。小さく描く場所では、それを縮めて描く。
/// ストアはアプリ全体で1つで、タイムラインやアカウント、絵文字のパレットをまたいで溜まるため。
@MainActor
public final class EmojiImageStore<Image: Sendable> {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private struct Listener {
        weak var owner: AnyObject?
        let onLoad: @MainActor (Set<URL>) -> Void
    }

    /// アニメーション版の読み込みの状態。コマそのものは`animations`に持つ。
    private enum AnimationState {
        case loading
        /// 2コマ以上ある。`animations`から捨てられていれば読み直す。
        case animated(Resolution)
        /// 1コマしかないか、大きすぎて動かさない。静止画で描く。
        case still
        case failed
    }

    /// 読んだ画像の高さ。
    private struct Resolution {
        /// 読むときに求めた高さのピクセル数。
        let pixelHeight: Int
        /// これより高く読めない。元の画像の大きさのまま読んだか、メモリの上限（静止画は`maxStillPixelCount`、アニメーションは`AnimatedImage.maxByteCount`）に収まる高さまで下げた。
        /// 高く求め直しても同じなので、読み直さない。極端に横長な画像を幅の上限（`ImageDecoder.maxPixelSize(forHeight:of:)`）のために求めた高さより低く読んだときは、
        /// 高く求め直せば高く読めるので、含めない。
        let isLargest: Bool

        /// `pixelHeight`の高さで描くために、読み直すか。拡大する割合が`upscaleTolerance`までなら、読み直さずに拡大して描く。
        func needsReload(for pixelHeight: Int) -> Bool {
            !isLargest && Double(self.pixelHeight) * EmojiImageStore.upscaleTolerance < Double(pixelHeight)
        }
    }

    private struct Still {
        let image: Image
        let resolution: Resolution
    }

    /// メモリに持つ静止画とコマの画像の、既定の高さのピクセル数。
    /// 文字の中の絵文字は行の高さ（ふつうの本文で20〜30pt）に合わせて描き、iPhoneの画面は1ptを3ピクセルで描くので、32ptまでは拡大せずに描けてぼけない。
    /// 幅は縦横の比で決まるので、長い辺ではなく高さで縮める（`ImageDecoder.maxPixelSize(forHeight:of:)`）。
    /// 元の大きさのまま持つとメモリを使いすぎるため縮める。これより大きく描く絵文字は、描く側が渡した高さで読み直す。
    public nonisolated static var pixelHeight: Int { 96 }

    /// 読み直さずに拡大して描いてよい割合。少し大きさの違う場所で描くたびに読み直さないため。
    /// 拡大で増える見え方の誤差を、描き直すこと自体（ぴったりの高さで描かずに縮めたり、少し拡大したりする）で避けられない誤差の1割までに抑える。
    /// サーバーの絵文字40個をFLIP（3倍の画面のppd 95）で測ると、2%拡大した誤差に比べて、10%で約11%、20%で約31%増え、増え方に境目はなかった。
    nonisolated static var upscaleTolerance: Double { 1.1 }

    /// 静止画1枚に使ってよいピクセル数。1024×1024（4MB）。大きく描く絵文字を高く読むときも、これを超えない高さで止める。
    /// 1枚で`stills`の上限（32MB）を超えると、入れたそばから捨てられ、描くたびに読み直し続けるため、上限の1/8に収める。
    nonisolated static var maxStillPixelCount: Int { 1024 * 1024 }

    /// `pixelHeight`の高さで描くために読む高さ。既定の高さを拡大して描ける高さ（`upscaleTolerance`）までは、既定の高さで読む。
    nonisolated static func loadHeight(for pixelHeight: Int) -> Int {
        Double(pixelHeight) > Double(Self.pixelHeight) * upscaleTolerance ? pixelHeight : Self.pixelHeight
    }

    private let fetch: Fetch
    private let maker: PlatformImageMaker<Image>
    /// 持っている画像より高く読み直す通信を今送ってよいなら、その目的。持っている画像で描けるので、質を上げる通信として送る（docs/network.md）。
    private let upgradePurpose: @MainActor () -> RequestPurpose?
    /// 縮めた静止画。96pxの高さで1枚40KBほどなので、正方形の絵文字なら800個ほど入る。
    /// 静止画は行を描き直すたびにここから求め直す。上限を超えたときだけ、使ってから一番長いものから捨てる。
    /// `NSCache`には持たない。`NSCache`はシステムの判断で中身を捨てるため。iOSシミュレーターでは、アプリが裏に回った知らせを送った直後に捨てた。
    /// 画面に出ている絵文字が捨てられると空けた場所で描いて読み直し、読み終えるとまた行を描き直す。
    /// Macで名前の絵文字が出たり消えたりを繰り返したときに`NSCache`から捨てられていたかと、何が捨てさせたかは確かめていない。
    /// 大きく描いた絵文字だけが、その高さで重くなる。
    private var stills = CostLimitedCache<URL, Still>(totalCostLimit: 32 * 1024 * 1024)
    /// 上限を超えて`stills`から捨てた静止画。もう一度描こうとして読み直した回数を数えるのに使う。
    private var evictedStills: Set<URL> = []
    private var stats = Stats()
    /// 読めなかった静止画。読み直している途中も、読めるまでは`:shortcode:`の文字で描き続けるため、読んでいる途中とは分けて持つ。
    private var failedStills: Set<URL> = []
    /// 静止画を読んでいる途中のURL。高さを上げて読み直している間も含む。
    private(set) var loading: Set<URL> = []
    /// アニメーション版を、高さを上げて読み直している途中のURL。読み終えるまで、前の高さのアニメーションで描き続ける。
    private(set) var upgradingAnimations: Set<URL> = []
    /// 読めなかった画像を、描いたときにいつ読み直すか。静止画とアニメーション版で共有する。URLが違うので混ざらない。
    private var retry: RetrySchedule
    private let clock: any Clock<Duration>
    /// 読めなかった画像ごとの、読み直してよくなるのを待つ処理（`scheduleRetry`）。
    private var retryWakes: [URL: Task<Void, Never>] = [:]
    private var animationStates: [URL: AnimationState] = [:]
    /// 描いている層がつかんでいるアニメーション。上限を超えて`animations`から捨てても、層が使っている間はコマが解放されないため、
    /// 読み直さずにこれを返す。読み直すと、捨てられた分をまた入れて別のものを押し出し、画面に出ているもの同士で読み直しを繰り返すため。
    private let liveAnimations = NSMapTable<NSURL, EmojiAnimation>.strongToWeakObjects()
    /// コマに分けたアニメーション。96pxのコマで、40コマの絵文字なら40個ほど。画面に一度に出る絵文字はそれより少ないため、スクロールして戻っても読み直しはまれ。
    /// 静止画と同じく`NSCache`には持たない。読み終えてから、知らせを受けた行が描き直して層がつかむまでは、ここのほかに持つものがない。
    /// その間にシステムの判断で捨てられると、描き直しで読み直し、読み終えるとまた捨てられて、動き出さないまま読み直しを繰り返す。
    /// macOSでテストを走らせたとき、読み終えても取り出せないまま、60秒の間に9万回あまり読み直したことがある。iOSシミュレーターでは、アプリが裏に回った知らせを送った直後に捨てた。
    private var animations = CostLimitedCache<URL, EmojiAnimation>(totalCostLimit: 64 * 1024 * 1024)
    private var listeners: [Listener] = []
    private var pendingNotification: Set<URL> = []
    private let logger = SciaLog.logger(category: "emoji")

    public init(
        clock: any Clock<Duration>,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy,
        maker: PlatformImageMaker<Image>,
        upgradePurpose: @escaping @MainActor () -> RequestPurpose?,
        fetch: @escaping Fetch
    ) {
        self.fetch = fetch
        self.maker = maker
        self.upgradePurpose = upgradePurpose
        self.clock = clock
        retry = RetrySchedule(policy: retryPolicy, clock: clock)
    }

    /// 読み込み済みなら画像を返す。まだなら読み込みを始めてnilを返す。
    /// 読めなかった画像は、間隔をおいてから読み直す。読み直してよくなった時刻に`addListener`で登録した処理に知らせるので、
    /// まだ描いている画面は描き直してこれを呼び、読み直させる（`scheduleRetry`）。
    /// - Parameters:
    ///   - pixelHeight: 描く高さのピクセル数。持っている画像より高ければ、その高さで読み直し、読み終えるまでは持っている画像を返す。
    ///     読み直すのは、質を上げる通信を送ってよいときだけ（`upgradePurpose`）。送れなければ、持っている画像を拡大して描く。
    ///   - retriesNow: 使う人が自分で見に行った操作（投稿のメニューを開くなど）で、間隔を待たずに読み直す。
    public func image(for url: URL, pixelHeight: Int = pixelHeight, retriesNow: Bool = false) -> Image? {
        let loadHeight = Self.loadHeight(for: pixelHeight)
        if let still = stills.value(forKey: url) {
            if still.resolution.needsReload(for: loadHeight), let purpose = retriesNow ? .action : upgradePurpose(), retriesNow || retry.allowsAutomaticLoad(of: url) {
                load(url, pixelHeight: loadHeight, purpose: purpose)
            }
            return still.image
        }
        // まだ読んでいない画像も、同じサーバーの`/media_proxy`が制限されている間は読まない（`RetrySchedule.rateLimitScope`）。
        // 初めて読むときは、大きく描くための高さでも通信の中身は同じなので、行に描く通信として送る。
        if retriesNow || retry.allowsAutomaticLoad(of: url) {
            load(url, pixelHeight: loadHeight, purpose: retriesNow ? .action : .display)
        }
        return nil
    }

    /// `url`のアニメーションを読み終えたか。動かすか静止画で描くかが決まっていればtrue。読み始めていなければfalse。
    public func hasFinishedLoadingAnimation(for url: URL) -> Bool {
        switch animationStates[url] {
        case .animated, .still, .failed: true
        case .loading, nil: false
        }
    }

    /// アニメーションする絵文字の、コマに分けた画像。`url`は絵文字の元の画像（`CustomEmoji.url`）を渡す。
    /// まだなら読み込みを始めてnilを返し、読み終えたら`addListener`で登録した処理に`url`を知らせる。1コマしかない画像や読めなかった画像でもnil。
    /// - Parameter pixelHeight: 描く高さのピクセル数。持っているコマより高ければ、その高さで読み直し、読み終えるまでは持っているコマを返す。
    ///   その高さでは`AnimatedImage.maxByteCount`を超えるときは、動きを止めないよう、収まる中で一番高く読む。
    ///   静止画と同じく、持っているコマより高く読み直すのは、質を上げる通信を送ってよいときだけ。
    public func animation(for url: URL, pixelHeight: Int = pixelHeight) -> EmojiAnimation? {
        let loadHeight = Self.loadHeight(for: pixelHeight)
        switch animationStates[url] {
        case .animated(let resolution):
            guard let animation = animations.value(forKey: url) ?? liveAnimations.object(forKey: url as NSURL) else {
                stats.animationReloads += 1
                loadAnimation(url, pixelHeight: max(loadHeight, resolution.pixelHeight))
                return nil
            }
            if resolution.needsReload(for: loadHeight), !upgradingAnimations.contains(url), let purpose = upgradePurpose(), retry.allowsAutomaticLoad(of: url) {
                upgradingAnimations.insert(url)
                loadAnimation(url, pixelHeight: loadHeight, purpose: purpose, replacing: resolution)
            }
            return animation
        case .failed:
            // 読めないうちは静止画で描き、間隔をおいてから読み直す。
            if retry.allowsAutomaticLoad(of: url) {
                loadAnimation(url, pixelHeight: loadHeight)
            }
            return nil
        case .loading, .still:
            return nil
        case nil:
            if retry.allowsAutomaticLoad(of: url) {
                loadAnimation(url, pixelHeight: loadHeight)
            }
            return nil
        }
    }

    public func hasFailed(_ url: URL) -> Bool {
        failedStills.contains(url)
    }

    /// 画像が届いたときに呼ぶ処理を登録する。`owner`が解放されると呼ばれなくなる。
    public func addListener(owner: AnyObject, onLoad: @escaping @MainActor (Set<URL>) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    /// 読んでいる途中に、もっと高く描くことになったときは、読み終えて知らせを受けた描く側が求め直したときに、読み直す。
    /// - Parameter purpose: 行に描いたときの読み込みは自動の通信として送り、止められている間は送らない（docs/network.md）。
    private func load(_ url: URL, pixelHeight: Int, purpose: RequestPurpose) {
        guard loading.insert(url).inserted else { return }
        if evictedStills.contains(url) {
            stats.stillReloads += 1
        }
        let maker = maker
        RequestPurpose.$current.withValue(purpose) { Task {
            defer { loading.remove(url) }
            do {
                let data = try await fetch(url)
                guard let (image, isLargest) = await Self.decodeStill(data, pixelHeight: pixelHeight) else { throw DecodeError() }
                let still = Still(image: maker.still(image), resolution: Resolution(pixelHeight: pixelHeight, isLargest: isLargest))
                evictedStills.formUnion(stills.setValue(still, forKey: url, cost: PlatformImageMaker<Image>.cost(of: image)))
                evictedStills.remove(url)
                stats.peakStillCost = max(stats.peakStillCost, stills.totalCost)
                failedStills.remove(url)
                retry.recordSuccess(for: url)
            } catch {
                logger.error("emoji load failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
                // 高さを上げて読み直すのに失敗したときは、持っている画像で描き続ける。
                retry.recordFailure(error, for: url)
                if stills.value(forKey: url) == nil {
                    failedStills.insert(url)
                    scheduleRetry(url)
                }
            }
            notify(url)
        } }
    }

    public struct DecodeError: Error {}

    /// 読み直しの回数を数える。解像度とキャッシュの上限を決めるときに、上限を超えて捨てたものをどれだけ読み直したかを見る。
    private struct Stats {
        /// 上限を超えて捨てた静止画を、もう一度描こうとして読み直した回数。
        var stillReloads = 0
        /// `animations`から捨てられ、描いている層もつかんでいなかったアニメーションを読み直した回数。
        var animationReloads = 0
        /// `stills`の重さの合計の、これまでの最大。
        var peakStillCost = 0
        /// 読み込んだアニメーションの重さの合計。読み直した分も足す。
        var animationBytes = 0
        /// 読み込んだアニメーション1つの重さの、これまでの最大。
        var largestAnimationBytes = 0
    }

    /// 状態ダンプ。URLは出さず、数だけを書く。
    public func stateDump() -> String {
        let kilobyte = 1024
        let resolutions = animationStates.values.compactMap { if case .animated(let resolution) = $0 { resolution } else { nil } }
        return [
            "pixelHeight: \(Self.pixelHeight) enlarged: \(stills.values.filter { $0.resolution.pixelHeight > Self.pixelHeight }.count)",
            "stills: \(stills.count) cost: \(stills.totalCost / kilobyte)KB peak: \(stats.peakStillCost / kilobyte)KB limit: \(stills.totalCostLimit / kilobyte)KB",
            "stillReloadsAfterEviction: \(stats.stillReloads) evictedNow: \(evictedStills.count)",
            "animated: \(resolutions.count) enlarged: \(resolutions.filter { $0.pixelHeight > Self.pixelHeight }.count) animationReloadsAfterEviction: \(stats.animationReloads)",
            "animationLoaded: \(stats.animationBytes / kilobyte)KB largest: \(stats.largestAnimationBytes / kilobyte)KB limit: \(animations.totalCostLimit / kilobyte)KB",
        ].joined(separator: "\n")
    }

    /// `url`のアニメーションの読み込みの状態。待ちが固まったテストで、どこで止まったかを見る。
    func animationDiagnosis(of url: URL) -> String {
        let state = animationStates[url].map { String(describing: $0) } ?? "nil"
        return [
            "animationState: \(state) cached: \(animations.contains(url)) live: \(liveAnimations.object(forKey: url as NSURL) != nil)",
            "upgrading: \(upgradingAnimations.contains(url)) retryWake: \(retryWakes[url] != nil) allowsAutomaticLoad: \(retry.allowsAutomaticLoad(of: url))",
            "animationReloadsAfterEviction: \(stats.animationReloads)",
        ].joined(separator: "\n")
    }

    /// 元の画像の、描く向きに直した大きさと、コマの数。
    private struct SourceSize {
        let width: Int
        let height: Int
        let frameCount: Int

        nonisolated init?(of data: Data) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0
            else { return nil }
            // `ImageDecoder.maxPixelSize(forHeight:of:)`と同じく、5から8の向きは90°回すので、縦横を入れ替える。
            if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
                swap(&width, &height)
            }
            self.width = width
            self.height = height
            frameCount = CGImageSourceGetCount(source)
        }

        /// 元の高さのまま読めた。丸めで1ピクセルほど低くなることがあるので、それも含める。
        nonisolated func isFullHeight(_ height: Int) -> Bool {
            height + 1 >= self.height
        }
    }

    /// 高さを`pixelHeight`にそろえて縮め、描く前に展開しておく。描くたびにメインスレッドで原寸のまま展開しないため。
    /// 元の画像より大きくはしない。拡大しても、ぼけは消えないため。`maxStillPixelCount`を超える大きさにもしない。
    /// カスタム絵文字は文字と一緒にSDRで描く決まりなので（docs/hdr-display.md）、HDRを求めずに読む。
    /// - Returns: 展開した画像と、これより高く読めないか（`Resolution.isLargest`）。
    @concurrent
    private static func decodeStill(_ data: Data, pixelHeight: Int) async -> (image: CGImage, isLargest: Bool)? {
        guard let source = SourceSize(of: data) else { return nil }
        var maxPixelSize = ImageDecoder.maxPixelSize(forHeight: pixelHeight, of: data)
        let longest = max(source.width, source.height)
        let scale = Double(min(maxPixelSize, longest)) / Double(longest)
        let pixelCount = Double(source.width * source.height) * scale * scale
        let isLimited = pixelCount > Double(maxStillPixelCount)
        if isLimited {
            maxPixelSize = Int((Double(longest) * (Double(maxStillPixelCount) / Double(source.width * source.height)).squareRoot()).rounded(.down))
        }
        guard let image = await ImageDecoder.thumbnail(of: data, maxPixelSize: maxPixelSize, dynamicRange: .standard) else { return nil }
        return (image, isLimited || source.isFullHeight(image.height))
    }

    /// `pixelHeight`の高さにそろえてコマに分ける。その高さでは`AnimatedImage.maxByteCount`を超えるときは、収まる高さまで下げる。
    /// ただし既定の高さ（`Self.pixelHeight`）より下げない。既定の高さでも超えるものは、今までどおり動かさない。
    /// - Returns: コマに分けた画像と、これより高く読めないか（`Resolution.isLargest`）。
    nonisolated private static func decodeAnimation(_ data: Data, pixelHeight: Int) async -> (image: AnimatedImage, isLargest: Bool)? {
        guard let source = SourceSize(of: data) else { return nil }
        let requested = ImageDecoder.maxPixelSize(forHeight: pixelHeight, of: data)
        let minimum = ImageDecoder.maxPixelSize(forHeight: Self.pixelHeight, of: data)
        let fitting = AnimatedImage.fittingPixelSize(frameCount: source.frameCount, width: source.width, height: source.height, maxPixelSize: requested)
        guard let image = await AnimatedImage.decode(data, maxPixelSize: max(min(minimum, requested), fitting)) else { return nil }
        return (image, fitting < requested || source.isFullHeight(image.frameHeight))
    }

    /// 動かすかは行に描くときに決めるため、初めて読むときは自動の通信として送る。
    /// - Parameters:
    ///   - purpose: 持っているコマより高く読み直すときは、質を上げる通信の目的を渡す。
    ///   - current: 高さを上げて読み直すときの、今の高さ。読み直せなかったときは今のコマで描き続け、同じ高さを求め直さないよう、これ以上読めないものとして残す。
    private func loadAnimation(_ url: URL, pixelHeight: Int, purpose: RequestPurpose = .display, replacing current: Resolution? = nil) {
        if current == nil {
            animationStates[url] = .loading
        }
        RequestPurpose.$current.withValue(purpose) { Task {
            defer { upgradingAnimations.remove(url) }
            let state: AnimationState
            do {
                let data = try await fetch(url)
                let decoded = await Task.detached(priority: .utility) {
                    await Self.decodeAnimation(data, pixelHeight: pixelHeight)
                }.value
                if let (image, isLargest) = decoded {
                    let animation = EmojiAnimation(image)
                    animations.setValue(animation, forKey: url, cost: image.byteCount)
                    stats.animationBytes += image.byteCount
                    stats.largestAnimationBytes = max(stats.largestAnimationBytes, image.byteCount)
                    liveAnimations.setObject(animation, forKey: url as NSURL)
                    state = .animated(Resolution(pixelHeight: pixelHeight, isLargest: isLargest))
                } else if let current {
                    state = .animated(Resolution(pixelHeight: current.pixelHeight, isLargest: true))
                } else {
                    state = .still
                }
                retry.recordSuccess(for: url)
            } catch {
                logger.error("emoji animation load failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
                // 高さを上げて読み直すのに失敗したときは、今のコマで描き続け、間隔をおいてから読み直す。
                state = current.map { .animated($0) } ?? .failed
                retry.recordFailure(error, for: url)
                if current == nil {
                    scheduleRetry(url)
                }
            }
            animationStates[url] = state
            if case .animated = state {
                notify(url)
            }
        } }
    }

    /// 読めなかった画像を、読み直してよくなった時刻に、まだ読めていなければ知らせる。待っても直らない失敗なら知らせない。
    /// ストアは描いている画面を知らないので、自分では読み直さず、知らせを受けて描き直した画面が求めたら読む。
    /// 描き直しを待つと、描き直されない画面は、間隔が過ぎても`:shortcode:`の文字のまま残るため（docs/network.md）。
    /// 描き直す画面がなければ読まないので、画面から外れた絵文字は読まない。隠れている画面に読ませないのは、描き直す側が受け持つ。
    /// 高さを上げて読み直すのに失敗したものは、持っている画像で描けているので知らせない。
    /// 取り消しのように失敗として覚えないものも知らせない。すぐ読んでよいことになるので、知らせると、描き直した画面が読み、待たずに繰り返すため。
    private func scheduleRetry(_ url: URL) {
        guard retryWakes[url] == nil, retry.hasFailed(url) else { return }
        let clock = clock
        retryWakes[url] = Task { [weak self] in
            let allowed = await RetrySchedule.waitUntilAutomaticLoad(clock: clock) { self?.retry.delayUntilAutomaticLoad(of: url) }
            guard let self else { return }
            retryWakes[url] = nil
            let isAnimationFailed = if case .failed? = animationStates[url] { true } else { false }
            if allowed, failedStills.contains(url) || isAnimationFailed {
                notify(url)
            }
        }
    }

    /// 同じ時期に届いた画像をまとめて知らせ、セルの再構成を減らす。
    private func notify(_ url: URL) {
        let isFirst = pendingNotification.isEmpty
        pendingNotification.insert(url)
        guard isFirst else { return }
        Task {
            let urls = pendingNotification
            pendingNotification = []
            listeners.removeAll { $0.owner == nil }
            for listener in listeners {
                listener.onLoad(urls)
            }
        }
    }
}

/// コマに分けたアニメーションする絵文字。描いている層が持っている間は、ストアから捨てても同じものを使い回す。
public final class EmojiAnimation: Sendable {
    public let image: AnimatedImage

    public init(_ image: AnimatedImage) {
        self.image = image
    }
}
