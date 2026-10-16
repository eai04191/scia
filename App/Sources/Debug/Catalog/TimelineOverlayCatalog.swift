#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 一覧の上に重ねて出す表示。ストリーミングが止まったときのナビゲーションバーの小見出し、新着のボタン、ログインし直しのボタン、
/// お気に入りやブーストの失敗のチップ。
/// 本物の一覧の画面をナビゲーションバーごと置き、一覧が外から受け取る操作で状態を作る。数秒で消えるチップは、カタログでは1時間出したままにする。
enum TimelineOverlayCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            state("ストリーミングが止まっている（小見出し）") { $0.setOutageNotice(true) },
            state("新着がある") { $0.setUnreadCount(12) },
            state("新着が読み込んだ分より多い") { $0.setUnreadCount(40, isLowerBound: true) },
            state("ログインし直しを促す") { $0.showReauthenticationPrompt(handle: "@catalog@example.com") {} },
            state("ログインし直しを始めた（読み込み中）") { timeline in
                timeline.showReauthenticationPrompt(handle: "@catalog@example.com") {}
                timeline.setReauthenticating(true)
            },
            state("ログインし直しを促す（長いアカウント名）") {
                $0.showReauthenticationPrompt(handle: "@a-very-long-account-name-for-checking-truncation@subdomain.example.com") {}
            },
            state("お気に入りの失敗（押すと理由）") { showFailure("お気に入りを変更できませんでした", on: $0) },
            state("ブーストの失敗を新着のボタンの下に出す") { timeline in
                timeline.setUnreadCount(12)
                showFailure("ブーストを変更できませんでした", on: timeline)
            },
            state("失敗の長い文言") {
                showFailure("長い文言のときにチップがどこまで広がり、どこで切れて「›」が残るかを確かめるための失敗", on: $0)
            },
            state("すべて同時に出す") { timeline in
                timeline.setOutageNotice(true)
                timeline.setUnreadCount(40, isLowerBound: true)
                timeline.showReauthenticationPrompt(handle: "@catalog@example.com") {}
                showFailure("お気に入りを変更できませんでした", on: timeline)
            },
        ]
    }

    @MainActor
    private static func showFailure(_ title: String, on timeline: TimelineViewController) {
        timeline.noticeStack.animationDuration = 0
        timeline.noticeStack.showTransient(.interactionFailure(title: title) {}, duration: 3600)
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
