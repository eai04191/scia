import Foundation
import os
import SciaCore
import UIKit

/// カスタム絵文字の画像を読み込み、メモリに持つ。
/// 静止画は、1つのタイムラインで使う絵文字は数百件程度で1枚も小さいため、上限を設けずに持ち続ける。
/// アニメーション版はコマの数だけメモリを使うため、上限を設けて、あふれたら古いものから捨て、また要るときに読み直す。
@MainActor
final class EmojiImageStore {
    typealias Fetch = @Sendable (URL) async throws -> Data

    private enum State {
        case loaded(UIImage)
        /// 読めなかった。読み直している途中も、読めるまでは`:shortcode:`の文字で描き続けるため、読んでいる途中とは分けて持つ。
        case failed
    }

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


    /// 動かすためにメモリに持つコマの画像の、長い辺のピクセル数。
    /// 文字の中の絵文字は行の高さ（ふつうの本文で20〜30pt）に合わせて描き、iPhoneの画面は1ptを3ピクセルで描くので、32ptまでは拡大せずに描けてぼけない。
    /// 元の大きさのまま持つとメモリを使いすぎるため縮める。文字サイズの設定を大きくして行の高さが32ptを超えると、拡大して描くので少しぼける。
    nonisolated static let animationPixelSize = 96

    private let fetch: Fetch
    private var states: [URL: State] = [:]
    /// 静止画を読んでいる途中のURL。
    private var loading: Set<URL> = []
    /// 読めなかった画像を、描いたときにいつ読み直すか。静止画とアニメーション版で共有する。URLが違うので混ざらない。
    private var retry: ImageRetrySchedule
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
        retryPolicy: @escaping @MainActor () -> ImageRetrySchedule.Policy = { TuningCatalog.imageRetry(in: AppDependencies.tuning) },
        fetch: @escaping Fetch
    ) {
        self.fetch = fetch
        retry = ImageRetrySchedule(policy: retryPolicy, clock: clock)
    }

    /// 読み込み済みなら画像を返す。まだなら読み込みを始めてnilを返す。
    /// 読めなかった画像は、間隔をおいてから読み直す。
    /// - Parameter retriesNow: 使う人が自分で見に行った操作（投稿のメニューを開くなど）で、間隔を待たずに読み直す。
    func image(for url: URL, retriesNow: Bool = false) -> UIImage? {
        switch states[url] {
        case .loaded(let image):
            return image
        case .failed:
            if retriesNow || retry.allowsAutomaticLoad(of: url) {
                load(url)
            }
            return nil
        case nil:
            load(url)
            return nil
        }
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
            loadAnimation(url)
            return nil
        }
    }

    func hasFailed(_ url: URL) -> Bool {
        if case .failed = states[url] { return true }
        return false
    }

    /// 画像が届いたときに呼ぶ処理を登録する。`owner`が解放されると呼ばれなくなる。
    func addListener(owner: AnyObject, onLoad: @escaping @MainActor (Set<URL>) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    private func load(_ url: URL) {
        guard loading.insert(url).inserted else { return }
        Task {
            defer { loading.remove(url) }
            do {
                let data = try await fetch(url)
                guard let image = UIImage(data: data) else { throw DecodeError() }
                states[url] = .loaded(image)
                retry.recordSuccess(for: url)
            } catch {
                logger.error("emoji load failed url=\(url.absoluteString, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                states[url] = .failed
                retry.recordFailure(error, for: url)
            }
            notify(url)
        }
    }

    struct DecodeError: Error {}

    private func loadAnimation(_ url: URL) {
        animationStates[url] = .loading
        Task {
            let state: AnimationState
            do {
                let data = try await fetch(url)
                let image = await Task.detached(priority: .utility) {
                    AnimatedImage.decode(data, maxPixelSize: Self.animationPixelSize)
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
                logger.error("emoji animation load failed url=\(url.absoluteString, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                state = .failed
                retry.recordFailure(error, for: url)
            }
            animationStates[url] = state
            if case .animated = state {
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
final class EmojiAnimation: Sendable {
    let image: AnimatedImage

    init(_ image: AnimatedImage) {
        self.image = image
    }
}
