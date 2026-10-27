import Foundation
import SciaCore

/// 一覧のスクロールが止まったときに画面に出ている画像を、ビューアで開く元の画像で1つずつ先読みする（docs/image-loading.mdの「ビューアで開く画像の先読み」）。
/// セッションごとに1つ持ち、そのセッションのどの一覧から渡されても同時には1つしか読まない。送るかは、読み始めるたびに回線と設定（`NetworkUsePolicy.prefetch`）で決める。
@MainActor
final class MediaPrefetcher {
    private let queue: PrefetchQueue<URL>

    /// - Parameter scope: 読む処理の持ち主。セッションの持ち主を渡し、ログアウトしたら止める。
    init(scope: TaskScope, store: MediaImageStore, network: NetworkConditionsMonitor, settings: AppSettings) {
        queue = PrefetchQueue(scope: scope) { [weak network, weak settings] url in
            guard let network, let settings, let purpose = network.usePolicy(settings: settings).prefetch else { return }
            await store.prefetchOriginal(url, purpose: purpose)
        }
    }

    /// 先読みする画像を差し替える。並びから外れた画像の読み込みは止める。空なら、読んでいる途中のものも止める。
    func prefetch(_ attachments: some Sequence<MediaAttachment>) {
        queue.replace(with: MediaPrefetch.urls(of: attachments))
    }
}
