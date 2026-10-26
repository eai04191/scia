import Foundation
import os
import SciaCore
import UIKit

/// カスタム絵文字の画像を読み込み、メモリに持つ。
/// 静止画もアニメーション版も、高さを`pixelHeight`にそろえて縮めて持ち、上限を設けて、あふれたら古いものから捨て、また要るときに読み直す。
/// ストアはアプリ全体で1つで、タイムラインやアカウント、絵文字のパレットをまたいで溜まるため。
@MainActor
final class EmojiImageStore {
    typealias Fetch = @Sendable (URL) async throws -> Data

    private struct Listener {
        weak var owner: AnyObject?
        let onLoad: @MainActor (Set<URL>) -> Void
    }

    /// アニメーション版の読み込みの状態。コマそのものは`animations`に持つ。
    private enum AnimationState {
        case loading
        /// 2コマ以上ある。`animations`から捨てられていれば読み直す。
        case animated
        /// 1コマしかないか、大きすぎて動かさない。静止画で描く。
        case still
        case failed
    }


    /// メモリに持つ静止画とコマの画像の、高さのピクセル数。
    /// 文字の中の絵文字は行の高さ（ふつうの本文で20〜30pt）に合わせて描き、iPhoneの画面は1ptを3ピクセルで描くので、32ptまでは拡大せずに描けてぼけない。
    /// 幅は縦横の比で決まるので、長い辺ではなく高さで縮める（`ImageDecoder.maxPixelSize(forHeight:of:)`）。
    /// 元の大きさのまま持つとメモリを使いすぎるため縮める。文字サイズの設定を大きくして行の高さが32ptを超えると、拡大して描くので少しぼける。
    nonisolated static let pixelHeight = 96

    private let fetch: Fetch
    /// 縮めた静止画。96pxの高さで1枚40KBほどなので、正方形の絵文字なら800個ほど入る。
    /// 静止画は行を描き直すたびにここから求め直す。上限を超えたときだけ、使ってから一番長いものから捨てる。
    /// `NSCache`には持たない。`NSCache`はシステムの判断で中身を捨てるため。iOSシミュレーターでは、アプリが裏に回った知らせを送った直後に捨てた。
    /// 画面に出ている絵文字が捨てられると空けた場所で描いて読み直し、読み終えるとまた行を描き直す。
    /// Macで名前の絵文字が出たり消えたりを繰り返したときに`NSCache`から捨てられていたかと、何が捨てさせたかは確かめていない。
    private var stills = CostLimitedCache<URL, UIImage>(totalCostLimit: 32 * 1024 * 1024)
    /// 読めなかった静止画。読み直している途中も、読めるまでは`:shortcode:`の文字で描き続けるため、読んでいる途中とは分けて持つ。
    private var failedStills: Set<URL> = []
    /// 静止画を読んでいる途中のURL。
    private var loading: Set<URL> = []
    /// 読めなかった画像を、描いたときにいつ読み直すか。静止画とアニメーション版で共有する。URLが違うので混ざらない。
    private var retry: RetrySchedule
    private var animationStates: [URL: AnimationState] = [:]
    /// 描いている層がつかんでいるアニメーション。`animations`から捨てても、層が使っている間はコマが解放されないため、
    /// 読み直さずにこれを返す。読み直すと、捨てられた分をまた入れて別のものを押し出し、画面に出ているもの同士で読み直しを繰り返すため。
    private let liveAnimations = NSMapTable<NSURL, EmojiAnimation>.strongToWeakObjects()
    private let animations: NSCache<NSURL, EmojiAnimation> = {
        let cache = NSCache<NSURL, EmojiAnimation>()
        // 96pxのコマで、40コマの絵文字なら40個ほど。画面に一度に出る絵文字はそれより少ないため、スクロールして戻っても読み直しはまれ。
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var listeners: [Listener] = []
    private var pendingNotification: Set<URL> = []
    private let logger = SciaLog.logger(category: "emoji")

    init(
        clock: any Clock<Duration> = AppDependencies.clock,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy = { TuningCatalog.imageRetry(in: AppDependencies.tuning) },
        fetch: @escaping Fetch
    ) {
        self.fetch = fetch
        retry = RetrySchedule(policy: retryPolicy, clock: clock)
    }

    /// 読み込み済みなら画像を返す。まだなら読み込みを始めてnilを返す。
    /// 読めなかった画像は、間隔をおいてから読み直す。
    /// - Parameter retriesNow: 使う人が自分で見に行った操作（投稿のメニューを開くなど）で、間隔を待たずに読み直す。
    func image(for url: URL, retriesNow: Bool = false) -> UIImage? {
        if let image = stills.value(forKey: url) {
            return image
        }
        // まだ読んでいない画像も、同じサーバーの`/media_proxy`が制限されている間は読まない（`RetrySchedule.rateLimitScope`）。
        if retriesNow || retry.allowsAutomaticLoad(of: url) {
            load(url, origin: retriesNow ? .user : .automatic)
        }
        return nil
    }

    /// `url`のアニメーションを読み終えたか。動かすか静止画で描くかが決まっていればtrue。読み始めていなければfalse。
    func hasFinishedLoadingAnimation(for url: URL) -> Bool {
        switch animationStates[url] {
        case .animated, .still, .failed: true
        case .loading, nil: false
        }
    }

    /// アニメーションする絵文字の、コマに分けた画像。`url`は絵文字の元の画像（`CustomEmoji.url`）を渡す。
    /// まだなら読み込みを始めてnilを返し、読み終えたら`addListener`で登録した処理に`url`を知らせる。1コマしかない画像や読めなかった画像でもnil。
    func animation(for url: URL) -> EmojiAnimation? {
        switch animationStates[url] {
        case .animated:
            if let animation = animations.object(forKey: url as NSURL) ?? liveAnimations.object(forKey: url as NSURL) {
                return animation
            }
            loadAnimation(url)
            return nil
        case .failed:
            // 読めないうちは静止画で描き、間隔をおいてから読み直す。
            if retry.allowsAutomaticLoad(of: url) {
                loadAnimation(url)
            }
            return nil
        case .loading, .still:
            return nil
        case nil:
            if retry.allowsAutomaticLoad(of: url) {
                loadAnimation(url)
            }
            return nil
        }
    }

    func hasFailed(_ url: URL) -> Bool {
        failedStills.contains(url)
    }

    /// 画像が届いたときに呼ぶ処理を登録する。`owner`が解放されると呼ばれなくなる。
    func addListener(owner: AnyObject, onLoad: @escaping @MainActor (Set<URL>) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    /// - Parameter origin: 行に描いたときの読み込みは自動の通信として送り、止められている間は送らない（docs/network.md）。
    private func load(_ url: URL, origin: RequestOrigin) {
        guard loading.insert(url).inserted else { return }
        RequestOrigin.$current.withValue(origin) { Task {
            defer { loading.remove(url) }
            do {
                let data = try await fetch(url)
                guard let image = await Self.decodeStill(data) else { throw DecodeError() }
                stills.setValue(image, forKey: url, cost: Self.cost(of: image))
                failedStills.remove(url)
                retry.recordSuccess(for: url)
            } catch {
                logger.error("emoji load failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
                failedStills.insert(url)
                retry.recordFailure(error, for: url)
            }
            notify(url)
        } }
    }

    struct DecodeError: Error {}

    /// 高さを`pixelHeight`にそろえて縮め、描く前に展開しておく。描くたびにメインスレッドで原寸のまま展開しないため。
    /// カスタム絵文字は文字と一緒にSDRで描く決まりなので（docs/hdr-display.md）、HDRを求めずに読む。
    @concurrent
    private static func decodeStill(_ data: Data) async -> UIImage? {
        let maxPixelSize = ImageDecoder.maxPixelSize(forHeight: pixelHeight, of: data)
        return ImageDecoder.thumbnail(of: data, maxPixelSize: maxPixelSize, dynamicRange: .standard).map { UIImage(cgImage: $0) }
    }

    private nonisolated static func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }

    /// 動かすかは行に描くときに決めるため、いつも自動の通信として送る。
    private func loadAnimation(_ url: URL) {
        animationStates[url] = .loading
        RequestOrigin.$current.withValue(.automatic) { Task {
            let state: AnimationState
            do {
                let data = try await fetch(url)
                let image = await Task.detached(priority: .utility) {
                    AnimatedImage.decode(data, maxPixelSize: ImageDecoder.maxPixelSize(forHeight: Self.pixelHeight, of: data))
                }.value
                if let image {
                    let animation = EmojiAnimation(image)
                    animations.setObject(animation, forKey: url as NSURL, cost: image.byteCount)
                    liveAnimations.setObject(animation, forKey: url as NSURL)
                    state = .animated
                } else {
                    state = .still
                }
                retry.recordSuccess(for: url)
            } catch {
                logger.error("emoji animation load failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
                state = .failed
                retry.recordFailure(error, for: url)
            }
            animationStates[url] = state
            if case .animated = state {
                notify(url)
            }
        } }
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
final class EmojiAnimation: Sendable {
    let image: AnimatedImage

    init(_ image: AnimatedImage) {
        self.image = image
    }
}
