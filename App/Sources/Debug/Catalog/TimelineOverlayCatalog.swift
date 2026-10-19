#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 一覧の上に重ねて出す表示。ストリーミングが止まったときのナビゲーションバーの小見出しと新着のボタン。
/// 本物の一覧の画面をナビゲーションバーごと置き、一覧が外から受け取る操作で状態を作る。数秒で消えるチップは、カタログでは1時間出したままにする。
enum TimelineOverlayCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            state("ストリーミングが止まっている（小見出し）") { $0.setOutageNotice(true) },
            state("新着がある") { $0.setUnreadCount(12) },
            state("新着が読み込んだ分より多い") { $0.setUnreadCount(40, isLowerBound: true) },
        ]
    }

    @MainActor
    private static func state(_ title: String, apply: @escaping @MainActor (TimelineViewController) -> Void) -> CatalogState {
        CatalogState(title: title) {
            // 状態ダンプを本物のホームと取り違えないよう、名前を分ける。
            let timeline = TimelineViewController(texts: TimelineViewController.Texts(
                dumpName: "catalog-timeline",
                title: "ホーム",
                empty: TimelineViewController.Texts.home.empty,
                reachedEnd: TimelineViewController.Texts.home.reachedEnd,
                unreadable: TimelineViewController.Texts.home.unreadable
            ))
            timeline.loadViewIfNeeded()
            // 中の一覧がスクロールすると、カタログのページを上下に送れなくなるため止める。
            timeline.collectionView.isScrollEnabled = false
            timeline.setContentState(.loaded)
            timeline.setEntries(statuses())
            apply(timeline)
            return CatalogControllerHost(UINavigationController(rootViewController: timeline), height: 360)
        }
    }

    /// ボタンが投稿に重なった見え方を確かめるため、一覧に投稿を並べておく。
    private static func statuses() -> [TimelineEntry] {
        let account = CatalogFixtures.account(displayName: "カタログのアカウント", acct: "catalog@example.com")
        return (1...4).map { index in
            .status(Status(
                id: "catalog-overlay-\(index)",
                createdAt: .now.addingTimeInterval(TimeInterval(-600 * index)),
                account: account,
                content: "<p>一覧の上に重ねる表示を確かめるための投稿 \(index)。</p>",
                spoilerText: "",
                url: nil
            ))
        }
    }
}
#endif
