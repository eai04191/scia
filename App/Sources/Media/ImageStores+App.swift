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
        fetch: @escaping Fetch
    ) {
        self.init(clock: clock, retryPolicy: retryPolicy, maker: .uiKit, fetch: fetch)
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
