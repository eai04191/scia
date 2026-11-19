public import CoreGraphics
public import Foundation
import ImageIO
import MemoryCache
import os
import Synchronization

/// カスタム絵文字の画像を読み込み、メモリに持つ。`Image`は描く側の画像の型で、iOSでは`UIImage`にする。
/// 静止画もアニメーション版も、高さを`pixelHeight`にそろえて縮めて持ち、上限を設けて、あふれたら古いものから捨て、また要るときに読み直す。
/// 絵文字だけの本文のように`pixelHeight`より大きく描くときは、描く側が要る高さを渡し、そのURLだけをその高さで読み直して置き換える。
/// 同じURLを大きさごとに別に持たず、1つのURLには、それまでに描いた一番大きい高さの画像を1つだけ持つ。小さく描く場所では、それを縮めて描く。
/// ストアはアプリ全体で1つで、タイムラインやアカウント、絵文字のパレットをまたいで溜まるため。
@MainActor
public final class EmojiImageStore<Image: AnyObject & Sendable> {
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
        /// 取れたが、画像として読めなかった。静止画で描くが、動くかは分からない。
        case unreadable
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
    /// 端末に置いた元の画像。通信しないので、読み直しの通信を送れないときも、これがあれば描く高さで作り直す（docs/network.md）。
    private let storedData: @Sendable (URL) async -> Data?
    /// 端末に画像を置き終えた回数。`storageMisses`を、置いたあとに見直すために比べる。
    private let storedWriteCount: @Sendable () -> Int
    /// 端末から作り直そうとして、元の画像がなかったか読めなかった絵文字と、そのときの`storedWriteCount`。
    /// 描くたびに端末を読みに行かないよう覚え、何か置かれたら（先読みなど別の経路を含む）見直す。
    private var storageMisses: [URL: Int] = [:]
    /// 端末から作り直している静止画とアニメーション。通信の読み込み（`loading`、`upgradingAnimations`）とは別に持ち、
    /// 端末を見ている間に届いた通信の要求や操作の要求を、読み込み中として見送らないようにする。
    private var reloadingStills: Set<URL> = []
    /// 端末から作り直している静止画の数。終えたことを、テストが時間を待たずに確かめるのに使う。
    var reloadingStillCount: Int { reloadingStills.count }
    private var reloadingAnimations: Set<URL> = []
    /// 縮めた静止画。96pxの高さで1枚40KBほどなので、正方形の絵文字なら800個ほど入る。大きく描いた絵文字だけが、その高さで重くなる。
    /// 静止画は行を描き直すたびにここから求め直す。何をいつ捨てるかはdocs/image-loading.mdの「メモリに持つ画像」に従う。
    /// 画面に出ている絵文字が捨てられると空けた場所で描いて読み直し、読み終えるとまた行を描き直す。
    private var stills = MemoryCache<URL, Image>(totalCostLimit: 32 * 1024 * 1024)
    /// `stills`に持つ静止画の高さ。`stills`が返さなくなったものは、求めたときと`removeReleasedStillResolutions`で消す。
    private var stillResolutions: [URL: Resolution] = [:]
    /// 高さを覚えている静止画の数。解放された静止画の高さを溜めないことを、テストで確かめる。
    var stillResolutionCount: Int { stillResolutions.count }
    /// `stillResolutions`がこの数を超えたら、`stills`が返さなくなったものを消す。消したあとに残った数の倍にする。
    private var stillResolutionCleanupThreshold = 64
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
    /// コマに分けたアニメーション。96pxのコマで、40コマの絵文字なら40個ほど。画面に一度に出る絵文字はそれより少ないため、スクロールして戻っても読み直しはまれ。
    /// 何をいつ捨てるかは静止画と同じ。読み終えてから、知らせを受けた行が描き直して層がつかむまでは、ここのほかに持つものがないので、
    /// システムの判断で捨てるキャッシュに持つと、描き直しで読み直し、読み終えるとまた捨てられて、動き出さないまま読み直しを繰り返す。
    /// macOSでテストを走らせたとき、`NSCache`に持っていて、読み終えても取り出せないまま60秒の間に9万回あまり読み直したことがある。
    private var animations = MemoryCache<URL, EmojiAnimation>(totalCostLimit: 64 * 1024 * 1024)
    private var listeners: [Listener] = []
    /// 元の画像を読んで動かさないと分かったときに知らせる先。描く側は静止画のまま描けているので、`listeners`には知らせない。
    /// 動きの選択肢を出すかを決める画面（`isKnownStill`）だけが使う。
    private var stillListeners: [Listener] = []
    /// 画像を読めたときに、元の画像の、描く向きに直した幅と高さを渡す。サーバーが縦横比を返さないカスタム絵文字の縦横比を、リストに残すために使う（`CustomEmojiCaches.learn`）。
    public var onSourceSize: (@MainActor (URL, Int, Int) -> Void)?
    /// 読んだデータを端末に残さないときに、URLを渡す。端末に置いたファイルを消すのに使う（`StoredImageFetch.discard`）。
    /// 画像として読めなかったデータと、大きすぎて動かせない元の画像で呼ぶ。動かせない元の画像は、次から動かない版を読むので、残しても使わない。
    public var onDiscard: (@Sendable (URL) async -> Void)?
    /// 静止画を展開したときに、URLと展開した画像を渡す。絵文字のパレットの小さい静止画を作るのに使う（`EmojiThumbnails`）。
    public var onStillDecoded: (@Sendable (URL, CGImage) -> Void)?
    /// 大きすぎて動かせないと分かった元の画像を残す先。nilなら残さない。
    public var oversized: OversizedEmojiRecord?
    /// 読んでいる途中の通信。同じURLの静止画とアニメーションを同時に求められたときに、1回の通信を分け合う。
    private var fetches: [URL: (purpose: RequestPurpose?, task: Task<(Data, ResponseSource?), any Error>)] = [:]
    private var pendingNotification: Set<URL> = []
    /// 端末のファイルから読んだ静止画の、知らせを配るまでの時間の記録。求められてからの長さを返す関数、ファイルを読み終えた時点、展開し終えた時点。
    private var arriving: [URL: (elapsed: @Sendable () -> Duration, fetched: Duration, decoding: DecodeTimes, decoded: Duration)] = [:]
    private let logger = SciaLog.logger(category: "emoji")

    public init(
        clock: any Clock<Duration>,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy,
        maker: PlatformImageMaker<Image>,
        upgradePurpose: @escaping @MainActor () -> RequestPurpose?,
        storedData: @escaping @Sendable (URL) async -> Data? = { _ in nil },
        storedWriteCount: @escaping @Sendable () -> Int = { 0 },
        fetch: @escaping Fetch
    ) {
        self.fetch = fetch
        self.maker = maker
        self.upgradePurpose = upgradePurpose
        self.storedData = storedData
        self.storedWriteCount = storedWriteCount
        self.clock = clock
        retry = RetrySchedule(policy: retryPolicy, clock: clock)
    }

    /// 描く場所が、絵文字の2つの画像のどちらを読むか。
    /// - Parameter animates: その場所で絵文字を動かすか。
    public func choice(animates: Bool) -> EmojiImageChoice {
        EmojiImageChoice(animates: animates, oversized: oversized)
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
        if let image = stills.value(forKey: url), let resolution = stillResolutions[url] {
            if resolution.needsReload(for: loadHeight) {
                if let purpose = retriesNow ? .action : upgradePurpose(), retriesNow || retry.allowsAutomaticLoad(of: url) {
                    load(url, pixelHeight: loadHeight, purpose: purpose)
                } else {
                    reloadStillFromStorage(url, pixelHeight: loadHeight)
                }
            }
            return image
        }
        stillResolutions[url] = nil
        // まだ読んでいない画像も、同じサーバーの`/media_proxy`が制限されている間は読まない（`RetrySchedule.rateLimitScope`）。
        // 初めて読むときは、大きく描くための高さでも通信の中身は同じなので、行に描く通信として送る。
        if retriesNow || retry.allowsAutomaticLoad(of: url) {
            load(url, pixelHeight: loadHeight, purpose: retriesNow ? .action : .display)
        }
        return nil
    }

    /// `url`のアニメーションを読み終えたか。動かすか静止画で描くかが決まっていればtrue。読み始めていなければfalse。
    public func hasFinishedLoadingAnimation(for url: URL) -> Bool {
        if oversized?.contains(url) == true { return true }
        return switch animationStates[url] {
        case .animated, .still, .unreadable, .failed: true
        case .loading, nil: false
        }
    }

    /// `url`の元の画像を読んで、動かさないと分かったか。1コマしかないか、大きすぎて動かせない画像。読んでいない、読めなかった画像ではfalse。
    public func isKnownStill(_ url: URL) -> Bool {
        if oversized?.contains(url) == true { return true }
        if case .still = animationStates[url] { return true }
        return false
    }

    /// アニメーションする絵文字の、コマに分けた画像。`url`は絵文字の元の画像（`CustomEmoji.url`）を渡す。
    /// まだなら読み込みを始めてnilを返し、読み終えたら`addListener`で登録した処理に`url`を知らせる。1コマしかない画像や読めなかった画像でもnil。
    /// - Parameter pixelHeight: 描く高さのピクセル数。持っているコマより高ければ、その高さで読み直し、読み終えるまでは持っているコマを返す。
    ///   その高さでは`AnimatedImage.maxByteCount`を超えるときは、動きを止めないよう、収まる中で一番高く読む。
    ///   静止画と同じく、持っているコマより高く読み直すのは、質を上げる通信を送ってよいときだけ。
    public func animation(for url: URL, pixelHeight: Int = pixelHeight) -> EmojiAnimation? {
        // 大きすぎて動かせないと分かっている元の画像は、読まない。
        if oversized?.contains(url) == true { return nil }
        let loadHeight = Self.loadHeight(for: pixelHeight)
        switch animationStates[url] {
        case .animated(let resolution):
            guard let animation = animations.value(forKey: url) else {
                stats.animationReloads += 1
                loadAnimation(url, pixelHeight: max(loadHeight, resolution.pixelHeight))
                return nil
            }
            if resolution.needsReload(for: loadHeight), !upgradingAnimations.contains(url) {
                if let purpose = upgradePurpose(), retry.allowsAutomaticLoad(of: url) {
                    upgradingAnimations.insert(url)
                    loadAnimation(url, pixelHeight: loadHeight, purpose: purpose, replacing: resolution)
                } else {
                    reloadAnimationFromStorage(url, pixelHeight: loadHeight)
                }
            }
            return animation
        case .failed:
            // 読めないうちは静止画で描き、間隔をおいてから読み直す。
            if retry.allowsAutomaticLoad(of: url) {
                loadAnimation(url, pixelHeight: loadHeight)
            }
            return nil
        case .loading, .still, .unreadable:
            return nil
        case nil:
            if retry.allowsAutomaticLoad(of: url) {
                loadAnimation(url, pixelHeight: loadHeight)
            }
            return nil
        }
    }

    /// 使っていない静止画とアニメーションをすべて手放す。描いている画像は残す。メモリ警告を受けたときに呼ぶ（docs/image-loading.mdの「メモリに持つ画像」）。
    public func releaseUnusedMemory() {
        stills.releaseUnused()
        animations.releaseUnused()
        removeReleasedStillResolutions()
    }

    /// `stills`が返さなくなった静止画の高さを消す。通り過ぎて描き直さない絵文字の高さを、起動している間ずっと溜めないため。
    private func removeReleasedStillResolutions() {
        stillResolutions = stillResolutions.filter { stills.contains($0.key) }
        stillResolutionCleanupThreshold = max(stillResolutions.count * 2, 64)
    }

    public func hasFailed(_ url: URL) -> Bool {
        failedStills.contains(url)
    }

    /// 先読みしてよいか。前に読めなかった画像と、読み直しを待っている間の画像は、先読みしない（docs/image-loading.mdの「読めなかった画像の読み直し」）。
    /// 読めない画像のために通信を増やさないため。
    public func allowsPrefetch(of url: URL) -> Bool {
        retry.allowsAutomaticLoad(of: url) && !retry.hasFailed(url)
    }

    /// 先読みで読めなかったことを、表示のための読み込みと同じく覚える。表示の側が、間隔を待たずに読み直さないため。
    /// 通信の失敗でなければ（止めた、など）覚えない。
    public func recordPrefetchFailure(_ error: any Error, for url: URL) {
        guard HTTPFailure(error) != nil else { return }
        retry.recordFailure(error, for: url)
    }

    /// 画像が届いたときに呼ぶ処理を登録する。`owner`が解放されると呼ばれなくなる。
    public func addListener(owner: AnyObject, onLoad: @escaping @MainActor (Set<URL>) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    /// 元の画像を読んで動かさないと分かったとき（`isKnownStill`がtrueになったとき）に、そのURLを知らせる。`owner`が解放されたら知らせない。
    public func addStillListener(owner: AnyObject, onStill: @escaping @MainActor (Set<URL>) -> Void) {
        stillListeners.append(Listener(owner: owner, onLoad: onStill))
    }

    /// 読んでいる途中に、もっと高く描くことになったときは、読み終えて知らせを受けた描く側が求め直したときに、読み直す。
    /// - Parameter purpose: 行に描いたときの読み込みは自動の通信として送り、止められている間は送らない（docs/network.md）。
    private func load(_ url: URL, pixelHeight: Int, purpose: RequestPurpose) {
        guard loading.insert(url).inserted else { return }
        let elapsed = stopwatch(on: clock)
        let isReload = evictedStills.contains(url)
        if isReload {
            stats.stillReloads += 1
        }
        let maker = maker
        RequestPurpose.$current.withValue(purpose) { Task {
            defer { loading.remove(url) }
            do {
                let (data, source, isShared) = try await fetchRecordingSource(url)
                let fetched = elapsed()
                let isFromFile = source == .file && !isShared
                stats.stillSources.count(source, isShared: isShared)
                if isReload {
                    stats.stillReloadSources.count(source, isShared: isShared)
                }
                guard let (image, isLargest, source, decoding) = await Self.decodeStill(data, pixelHeight: pixelHeight, elapsed: elapsed) else { throw DecodeError() }
                // 大きすぎて動かせないと分かった元の画像を、静止画がメモリから捨てられて読み直したときも、端末に残さない。
                if oversized?.contains(url) == true {
                    await onDiscard?(url)
                }
                onSourceSize?(url, source.width, source.height)
                onStillDecoded?(url, image)
                evictedStills.formUnion(stills.setValue(maker.still(image), forKey: url, cost: PlatformImageMaker<Image>.cost(of: image)))
                stillResolutions[url] = Resolution(pixelHeight: pixelHeight, isLargest: isLargest)
                if stillResolutions.count > stillResolutionCleanupThreshold {
                    removeReleasedStillResolutions()
                }
                evictedStills.remove(url)
                stats.peakStillCost = max(stats.peakStillCost, stills.totalCost)
                failedStills.remove(url)
                retry.recordSuccess(for: url)
                if isFromFile {
                    arriving[url] = (elapsed, fetched, decoding, elapsed())
                }
            } catch {
                let error = recordFailure(error, for: url)
                logger.error("emoji load failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
                if error is DecodeError {
                    await onDiscard?(url)
                }
                // 高さを上げて読み直すのに失敗したときは、持っている画像で描き続ける。
                if !stills.contains(url) {
                    failedStills.insert(url)
                    scheduleRetry(url)
                }
            }
            notify(url)
        } }
    }

    /// 読み直しの通信を送れないときに、端末に置いた元の画像があれば、通信せずに描く高さで作り直す。
    /// なかったか読めなかったら、何か置かれるまで見に行かない。終えたら知らせ、見ている間に見送った描き直しを求め直させる。
    private func reloadStillFromStorage(_ url: URL, pixelHeight: Int) {
        guard !isStorageMiss(url), reloadingStills.insert(url).inserted else { return }
        let writeCount = storedWriteCount()
        Task(.withoutRequests) { [self] in
            defer {
                reloadingStills.remove(url)
                notify(url)
            }
            let elapsed = stopwatch(on: clock)
            guard let data = await storedData(url),
                  let (image, isLargest, source, _) = await Self.decodeStill(data, pixelHeight: pixelHeight, elapsed: elapsed)
            else {
                storageMisses[url] = writeCount
                return
            }
            // 作り直している間に、通信でもっと高く読めていたら、低い画像で上書きしない。
            if let current = stillResolutions[url], current.pixelHeight >= pixelHeight { return }
            onSourceSize?(url, source.width, source.height)
            onStillDecoded?(url, image)
            evictedStills.formUnion(stills.setValue(maker.still(image), forKey: url, cost: PlatformImageMaker<Image>.cost(of: image)))
            stillResolutions[url] = Resolution(pixelHeight: pixelHeight, isLargest: isLargest)
            evictedStills.remove(url)
            stats.peakStillCost = max(stats.peakStillCost, stills.totalCost)
        }
    }

    /// `reloadStillFromStorage`のアニメーション版。
    private func reloadAnimationFromStorage(_ url: URL, pixelHeight: Int) {
        guard !isStorageMiss(url), reloadingAnimations.insert(url).inserted else { return }
        let writeCount = storedWriteCount()
        Task(.withoutRequests) { [self] in
            defer { reloadingAnimations.remove(url) }
            guard let data = await storedData(url),
                  let (image, isLargest, _) = await Task.detached(priority: .utility, operation: { await Self.decodeAnimation(data, pixelHeight: pixelHeight) }).value
            else {
                storageMisses[url] = writeCount
                return
            }
            if case .animated(let current) = animationStates[url], current.pixelHeight >= pixelHeight { return }
            animations.setValue(EmojiAnimation(image), forKey: url, cost: image.byteCount)
            stats.animationBytes += image.byteCount
            stats.largestAnimationBytes = max(stats.largestAnimationBytes, image.byteCount)
            animationStates[url] = .animated(Resolution(pixelHeight: pixelHeight, isLargest: isLargest))
            notify(url)
        }
    }

    /// 前に端末から作り直そうとして、なかったか読めなかったか。そのあと何か置かれていれば、見直す。
    private func isStorageMiss(_ url: URL) -> Bool {
        guard let writeCount = storageMisses[url] else { return false }
        if writeCount == storedWriteCount() { return true }
        storageMisses[url] = nil
        return false
    }

    public struct DecodeError: Error {}

    /// 読み、応答を通信で受け取ったかキャッシュから読んだかも返す。通信の層が知らせなければnil。
    /// 同じURLを同じ目的で読んでいる途中なら、その通信を待って同じデータを受け取る。動かす場所は、同じ元の画像から静止画とアニメーションを作るため。
    /// - Returns: データと、応答の出どころ。読んでいる途中の通信を分け合ったときは`isShared`がtrue。
    private func fetchRecordingSource(_ url: URL) async throws -> (data: Data, source: ResponseSource?, isShared: Bool) {
        let purpose = RequestPurpose.current
        if let running = fetches[url], running.purpose == purpose {
            do {
                let (data, source) = try await running.task.value
                return (data, source, true)
            } catch {
                throw SharedFetchFailure(underlying: error)
            }
        }
        let fetch = fetch
        let task = Task {
            let reported = ReportedSource()
            let data = try await ResponseSource.$report.withValue({ source in reported.value.withLock { $0 = source } }) {
                try await fetch(url)
            }
            return (data, reported.value.withLock { $0 })
        }
        // 目的の違う通信が走っていれば、分け合う相手には登録しない。
        let isRegistered = fetches[url] == nil
        if isRegistered {
            fetches[url] = (purpose, task)
        }
        defer {
            if isRegistered {
                fetches[url] = nil
            }
        }
        let (data, source) = try await task.value
        return (data, source, false)
    }

    /// 分け合った通信の失敗。通信を始めた側が失敗を覚えるので、分け合った側は覚えない。両方で覚えると、1回の失敗を2回と数える。
    private struct SharedFetchFailure: Error {
        let underlying: any Error
    }

    /// `error`を失敗として覚える。分け合った通信の失敗なら、覚えずに元の失敗を返す。
    private func recordFailure(_ error: any Error, for url: URL) -> any Error {
        if let shared = error as? SharedFetchFailure { return shared.underlying }
        retry.recordFailure(error, for: url)
        return error
    }

    private final class ReportedSource: Sendable {
        let value = Mutex<ResponseSource?>(nil)
    }

    /// 読んだ応答を、通信で受け取ったもの、応答のキャッシュから読んだもの、端末に置いたファイルから読んだものに分けて数える。
    private struct SourceCounts: CustomStringConvertible {
        var network = 0
        var cache = 0
        var file = 0
        var unknown = 0
        /// 読んでいる途中の同じURLの通信を分け合った回数。通信もファイルの読み出しも増やしていない。
        var shared = 0

        mutating func count(_ source: ResponseSource?, isShared: Bool) {
            if isShared {
                shared += 1
                return
            }
            switch source {
            case .network: network += 1
            case .cache: cache += 1
            case .file: file += 1
            case nil: unknown += 1
            }
        }

        var description: String { "network \(network) cache \(cache) file \(file) unknown \(unknown) shared \(shared)" }
    }

    /// 端末のファイルから読んだ静止画が、求められてから描き直されるまでの時間の内訳。空いた枠が見える長さが、どの段で決まっているかを見る。
    /// 新しいほうから`maxCount`個までを持つ。
    private struct ArrivalTimes: CustomStringConvertible {
        /// 段の名前。ファイルを読む（順番待ちを含む）、メインスレッドの外に移る、展開のキューを待つ、展開する、メインスレッドに戻るのを待つ、
        /// 知らせを配るまで待つ、知らせを受けた画面が描き直す。
        static var stages: [String] { ["fetch", "leaveMain", "decodeQueue", "decodeRun", "returnToMain", "deliver", "redraw", "total"] }
        /// 段ごとの長さ（ミリ秒）。
        var samples: [String: [Double]] = [:]

        /// 持っておく記録の数。超えたら古い半分を捨てる。起動している間、読み直すたびに溜め続けないため。
        static var maxCount: Int { 8_192 }

        mutating func record(fetched: Duration, decoding: DecodeTimes, decoded: Duration, delivered: Duration, redrawn: Duration) {
            if (samples["total"]?.count ?? 0) >= Self.maxCount {
                for stage in Self.stages {
                    samples[stage]?.removeFirst(Self.maxCount / 2)
                }
            }
            func milliseconds(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15 }
            let marks = [.zero, fetched, decoding.entered, decoding.started, decoding.finished, decoded, delivered, redrawn]
            for (index, stage) in Self.stages.dropLast().enumerated() {
                samples[stage, default: []].append(milliseconds(marks[index + 1] - marks[index]))
            }
            samples["total", default: []].append(milliseconds(redrawn))
        }

        var description: String {
            func summary(_ values: [Double]) -> String {
                let sorted = values.sorted()
                guard let last = sorted.last else { return "-" }
                func at(_ ratio: Double) -> String { String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * ratio))]) }
                return "min \(String(format: "%.2f", sorted[0])) p10 \(at(0.1)) p50 \(at(0.5)) p90 \(at(0.9)) max \(String(format: "%.1f", last))"
            }
            return (["count \(samples["total"]?.count ?? 0)"] + Self.stages.map { "\($0) \(summary(samples[$0] ?? []))" }).joined(separator: " | ")
        }
    }

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
        /// 読めた静止画とアニメーションの応答の出どころ。捨てたものの読み直しが通信になっているかを見る。
        var stillSources = SourceCounts()
        var stillReloadSources = SourceCounts()
        var animationSources = SourceCounts()
        var stillArrival = ArrivalTimes()
    }

    /// 状態ダンプ。URLは出さず、数だけを書く。
    public func stateDump() -> String {
        let kilobyte = 1024
        let resolutions = animationStates.values.compactMap { if case .animated(let resolution) = $0 { resolution } else { nil } }
        return [
            "pixelHeight: \(Self.pixelHeight) enlarged: \(stillResolutions.filter { stills.contains($0.key) && $0.value.pixelHeight > Self.pixelHeight }.count)",
            "stills: \(stills.count) cost: \(stills.totalCost / kilobyte)KB peak: \(stats.peakStillCost / kilobyte)KB limit: \(stills.totalCostLimit / kilobyte)KB",
            "stillReloadsAfterEviction: \(stats.stillReloads) evictedNow: \(evictedStills.count)",
            "stillFetched: \(stats.stillSources) afterEviction: \(stats.stillReloadSources)",
            "animationFetched: \(stats.animationSources)",
            "stillArrivalFromFileMs: \(stats.stillArrival)",
            "animated: \(resolutions.count) enlarged: \(resolutions.filter { $0.pixelHeight > Self.pixelHeight }.count) animationReloadsAfterEviction: \(stats.animationReloads)",
            "animationLoaded: \(stats.animationBytes / kilobyte)KB largest: \(stats.largestAnimationBytes / kilobyte)KB limit: \(animations.totalCostLimit / kilobyte)KB",
        ].joined(separator: "\n")
    }

    /// `url`のアニメーションの読み込みの状態。待ちが固まったテストで、どこで止まったかを見る。
    func animationDiagnosis(of url: URL) -> String {
        let state = animationStates[url].map { String(describing: $0) } ?? "nil"
        return [
            "animationState: \(state) cached: \(animations.contains(url))",
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
    /// - Returns: 展開した画像と、これより高く読めないか（`Resolution.isLargest`）と、元の画像の大きさ。
    /// - Parameter elapsed: 求められてからの長さを返す関数。展開の段の内訳（`DecodeTimes`）を測るのに使う。
    @concurrent
    private static func decodeStill(_ data: Data, pixelHeight: Int, elapsed: @escaping @Sendable () -> Duration) async -> (image: CGImage, isLargest: Bool, source: SourceSize, times: DecodeTimes)? {
        let entered = elapsed()
        guard let source = SourceSize(of: data) else { return nil }
        var maxPixelSize = ImageDecoder.maxPixelSize(forHeight: pixelHeight, of: data)
        let longest = max(source.width, source.height)
        let scale = Double(min(maxPixelSize, longest)) / Double(longest)
        let pixelCount = Double(source.width * source.height) * scale * scale
        let isLimited = pixelCount > Double(maxStillPixelCount)
        if isLimited {
            maxPixelSize = Int((Double(longest) * (Double(maxStillPixelCount) / Double(source.width * source.height)).squareRoot()).rounded(.down))
        }
        let size = maxPixelSize
        let (image, started, finished) = await ImageDecoder.run {
            let started = elapsed()
            let image = CGImageSourceCreateWithData(data as CFData, nil).flatMap { ImageDecoder.thumbnail(of: $0, maxPixelSize: size, dynamicRange: .standard) }
            return (image, started, elapsed())
        }
        guard let image else { return nil }
        return (image, isLimited || source.isFullHeight(image.height), source, DecodeTimes(entered: entered, started: started, finished: finished))
    }

    /// 静止画の展開の段の、求められてからの時点。メインスレッドの外に移った時点、展開のキューを受け取って展開を始めた時点、展開を終えた時点。
    private struct DecodeTimes: Sendable {
        let entered: Duration
        let started: Duration
        let finished: Duration
    }

    /// `pixelHeight`の高さにそろえてコマに分ける。その高さでは`AnimatedImage.maxByteCount`を超えるときは、収まる高さまで下げる。
    /// ただし既定の高さ（`Self.pixelHeight`）より下げない。既定の高さでも超えるものは、今までどおり動かさない。
    /// - Returns: コマに分けた画像と、これより高く読めないか（`Resolution.isLargest`）と、元の画像の大きさ。
    nonisolated private static func decodeAnimation(_ data: Data, pixelHeight: Int) async -> (image: AnimatedImage, isLargest: Bool, source: SourceSize)? {
        guard let source = SourceSize(of: data) else { return nil }
        let requested = ImageDecoder.maxPixelSize(forHeight: pixelHeight, of: data)
        let minimum = ImageDecoder.maxPixelSize(forHeight: Self.pixelHeight, of: data)
        let fitting = AnimatedImage.fittingPixelSize(frameCount: source.frameCount, width: source.width, height: source.height, maxPixelSize: requested)
        guard let image = await AnimatedImage.decode(data, maxPixelSize: max(min(minimum, requested), fitting)) else { return nil }
        return (image, fitting < requested || source.isFullHeight(image.frameHeight), source)
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
            let state: AnimationState?
            do {
                let (data, source, isShared) = try await fetchRecordingSource(url)
                stats.animationSources.count(source, isShared: isShared)
                // 動かせない画像（1コマ、大きすぎる）は読めているので、画像として読めないデータと分ける。
                let (decoded, size) = await Task.detached(priority: .utility) {
                    let decoded = await Self.decodeAnimation(data, pixelHeight: pixelHeight)
                    return (decoded, decoded?.source ?? SourceSize(of: data))
                }.value
                if let size {
                    // 大きすぎて動かせないと分かった元の画像は、大きさを残し、次から動かない版を読む。データは端末に残さない。
                    if decoded == nil, AnimatedImage.exceedsEmojiLimits(frameCount: size.frameCount, width: size.width, height: size.height, emojiPixelHeight: Self.pixelHeight) {
                        oversized?.record(url, width: size.width, height: size.height, frameCount: size.frameCount)
                        await onDiscard?(url)
                    }
                } else {
                    await onDiscard?(url)
                }
                if let (image, isLargest, source) = decoded {
                    onSourceSize?(url, source.width, source.height)
                    let animation = EmojiAnimation(image)
                    animations.setValue(animation, forKey: url, cost: image.byteCount)
                    stats.animationBytes += image.byteCount
                    stats.largestAnimationBytes = max(stats.largestAnimationBytes, image.byteCount)
                    state = .animated(Resolution(pixelHeight: pixelHeight, isLargest: isLargest))
                } else if let current {
                    state = .animated(Resolution(pixelHeight: current.pixelHeight, isLargest: true))
                } else if oversized?.contains(url) == true {
                    // 動かせないことは記録が覚えている。ここで覚えると、記録を消したあとに読み直さず、残し直せない。
                    state = nil
                } else {
                    state = size == nil ? .unreadable : .still
                }
                retry.recordSuccess(for: url)
            } catch {
                let error = recordFailure(error, for: url)
                logger.error("emoji animation load failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
                // 高さを上げて読み直すのに失敗したときは、今のコマで描き続け、間隔をおいてから読み直す。
                state = current.map { .animated($0) } ?? .failed
                if current == nil {
                    scheduleRetry(url)
                }
            }
            animationStates[url] = state
            switch state {
            case .animated:
                notify(url)
            case .still:
                stillListeners.removeAll { $0.owner == nil }
                for listener in stillListeners {
                    listener.onLoad([url])
                }
            case .loading, .unreadable, .failed, nil:
                break
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
            let arrived = urls.compactMap { arriving.removeValue(forKey: $0) }.map { ($0, $0.elapsed()) }
            for listener in listeners {
                listener.onLoad(urls)
            }
            for (arrival, delivered) in arrived {
                stats.stillArrival.record(fetched: arrival.fetched, decoding: arrival.decoding, decoded: arrival.decoded, delivered: delivered, redrawn: arrival.elapsed())
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
