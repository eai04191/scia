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
