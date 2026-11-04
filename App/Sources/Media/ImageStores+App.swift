import Foundation
import SciaCore
import UIKit

extension PlatformImageMaker where Image == UIImage {
    /// `UIImage`で作る。動く画像は`UIImage.animatedImage`で、コマを均等な間隔で流す。
    static var uiKit: PlatformImageMaker<UIImage> {
        PlatformImageMaker(
            still: { UIImage(cgImage: $0) },
            animated: { frames, duration in UIImage.animatedImage(with: frames.map { UIImage(cgImage: $0) }, duration: duration) }
        )
    }
}

extension UIView {
    /// ウィンドウにあり、自分も祖先も隠れていない。スクロールして画面の外に出ただけのビューは含む。
    /// 読めなかった画像を、見えている間だけ読み直すのに使う（`RetrySchedule.loadWhileShown`）。
    var isInVisibleHierarchy: Bool {
        guard window != nil else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha == 0 {
                return false
            }
            view = current.superview
        }
        return true
    }
}

extension AvatarImageStore where Image == UIImage {
    convenience init(
        clock: any Clock<Duration> = AppDependencies.clock,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy = { TuningCatalog.imageRetry(in: AppDependencies.tuning) },
        fetch: @escaping Fetch
    ) {
        self.init(clock: clock, retryPolicy: retryPolicy, maker: .uiKit, fetch: fetch)
    }
}

extension EmojiImageStore where Image == UIImage {
    convenience init(
        clock: any Clock<Duration> = AppDependencies.clock,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy = { TuningCatalog.imageRetry(in: AppDependencies.tuning) },
        upgradePurpose: @escaping @MainActor () -> RequestPurpose? = { AppDependencies.network.usePolicy(settings: AppDependencies.settings).enhancement },
        fetch: @escaping Fetch
    ) {
        self.init(clock: clock, retryPolicy: retryPolicy, maker: .uiKit, upgradePurpose: upgradePurpose, fetch: fetch)
    }
}

extension EmojiImageStore where Image == UIImage {
    /// `view`がウィンドウにある間だけ知らせを受ける。ウィンドウにない間（ほかのタブ、上に重ねた画面の下）に届いた知らせは溜め、
    /// ウィンドウに入ったときにまとめて渡す。ストアは、読めなかった絵文字を読み直してよくなったときにも知らせ、描き直した画面が求めると読みに行くため、
    /// 隠れた画面が描き直すと、見えていない絵文字を読む（docs/network.md）。`view`が解放されると呼ばれなくなる。
    func addListener(whileShownIn view: UIView, onLoad: @escaping @MainActor (Set<URL>) -> Void) {
        let gate = EmojiArrivalGate(onLoad: onLoad)
        view.addSubview(gate)
        addListener(owner: gate) { [weak gate] urls in gate?.receive(urls) }
    }
}

/// ウィンドウにない間の知らせを溜める、大きさのない隠したビュー。ウィンドウに入ったことを`didMoveToWindow`で知るために、知らせを受ける画面に置く。
private final class EmojiArrivalGate: UIView {
    private let onLoad: @MainActor (Set<URL>) -> Void
    private var pending: Set<URL> = []

    init(onLoad: @escaping @MainActor (Set<URL>) -> Void) {
        self.onLoad = onLoad
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func receive(_ urls: Set<URL>) {
        guard window != nil else {
            pending.formUnion(urls)
            return
        }
        onLoad(urls)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        onLoad(urls)
    }
}

extension MediaImageStore<UIImage> where Image == UIImage {
    convenience init(
        files: MediaFileCache,
        prefetchedFiles: MediaFileCache? = nil,
        clock: any Clock<Duration> = AppDependencies.clock,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy = { TuningCatalog.imageRetry(in: AppDependencies.tuning) },
        fetch: @escaping Fetch
    ) {
        self.init(files: files, prefetchedFiles: prefetchedFiles, clock: clock, retryPolicy: retryPolicy, maker: .uiKit, fetch: fetch)
    }
}
