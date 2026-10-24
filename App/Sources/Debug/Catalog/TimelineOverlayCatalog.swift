#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 一覧の上に重ねて出す表示。ストリーミングが止まったときのナビゲーションバーの小見出し、新着のボタンと、
/// ウインドウに重ねるチップの列（ログインし直しの段、お気に入りやブーストの失敗、ダウンロード中）。
/// 本物の一覧の画面をナビゲーションバーごと置き、一覧が外から受け取る操作で状態を作る。チップの列は、本物と同じく一覧が伝える位置に重ねる。
/// 数秒で消えるチップは、カタログでは1時間出したままにする。
enum TimelineOverlayCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        let handle = "@catalog@example.com"
        return [
            state("ストリーミングが止まっている（小見出し）") { timeline, _ in timeline.setOutageNotice(true) },
            state("新着がある") { timeline, _ in timeline.setUnreadCount(12) },
            state("新着が読み込んだ分より多い") { timeline, _ in timeline.setUnreadCount(40, isLowerBound: true) },
            state("ログインし直しを促す") { _, column in column.setReauthentication(NoticeCatalog.reauthentication(handle), animated: false) },
            state("ログインし直しを促す（新着のボタンに重ねる）") { timeline, column in
                timeline.setUnreadCount(12)
                column.setReauthentication(NoticeCatalog.reauthentication(handle), animated: false)
            },
            state("リンクをコピーしましたを新着のボタンと並べる") { timeline, column in
                timeline.setUnreadCount(12)
                column.stack.showTransient(.linkCopied, duration: 3600)
            },
            state("お気に入りの失敗（押すと理由）") { _, column in showFailure("お気に入りを変更できませんでした", on: column) },
            state("ブーストの失敗を新着のボタンに重ねる") { timeline, column in
                timeline.setUnreadCount(12)
                showFailure("ブーストを変更できませんでした", on: column)
            },
            state("ビューアを閉じたあとのダウンロード中（1件、押すと止めるかの確認）") { timeline, column in
                timeline.setUnreadCount(12)
                column.stack.setPersistent(.download(of: catalogURL, fraction: 0.42) {})
            },
            state("ビューアを閉じたあとのダウンロード中（2件以上は件数）") { timeline, column in
                timeline.setUnreadCount(12)
                column.stack.setPersistent(.downloads(count: 2, action: .disclosure(hint: "操作の状況を開きます。") {}))
            },
            state("ダウンロード中と、ほかのものを写真に保存しました") { _, column in
                column.stack.setPersistent(.download(of: catalogURL, fraction: 0.42) {})
                column.stack.showTransient(.savedToPhotos, duration: 3600)
            },
            state("ビューアを閉じたあとの失敗（種類で示す）") { _, column in
                column.stack.showTransient(.transferFailure(title: Notice.transferFailureTitle(of: .video, purpose: .save)) {}, duration: 3600)
            },
            state("すべて同時に出す") { timeline, column in
                timeline.setOutageNotice(true)
                timeline.setUnreadCount(40, isLowerBound: true)
                column.setReauthentication(NoticeCatalog.reauthentication(handle), animated: false)
                column.stack.setPersistent(.download(of: catalogURL, fraction: 0.42) {})
                showFailure("お気に入りを変更できませんでした", on: column)
            },
        ]
    }

    private static let catalogURL = URL(string: "https://x.example/video.mp4") ?? URL(filePath: "/")

    @MainActor
    private static func showFailure(_ title: String, on column: NoticeColumnView) {
        column.stack.showTransient(.interactionFailure(title: title) {}, duration: 3600)
    }

    @MainActor
    private static func state(_ title: String, apply: @escaping @MainActor (TimelineViewController, NoticeColumnView) -> Void) -> CatalogState {
        CatalogState(title: title) {
            // 状態ダンプを本物のホームと取り違えないよう、名前を分ける。
            let timeline = TimelineViewController(texts: TimelineViewController.Texts(
                dumpName: "catalog-timeline",
                title: "ホーム",
                empty: TimelineViewController.Texts.home.empty,
                reachedEnd: TimelineViewController.Texts.home.reachedEnd,
                unreadable: TimelineViewController.Texts.home.unreadable
            ), refresh: {})
            timeline.loadViewIfNeeded()
            // 中の一覧がスクロールすると、カタログのページを上下に送れなくなるため止める。
            timeline.collectionView.isScrollEnabled = false
            timeline.setContentState(.loaded)
            timeline.setEntries(statuses())
            let column = NoticeCatalog.makeColumn(reauthentication: nil)
            apply(timeline, column)
            let host = CatalogControllerHost(UINavigationController(rootViewController: timeline), height: 360)
            host.addOverlay(column) { host, column in
                let top = host.convert(CGPoint(x: 0, y: timeline.noticeTop), from: timeline.view).y
                let width = host.bounds.width - 32
                column.frame = CGRect(x: 16, y: top, width: width, height: (column as? NoticeColumnView)?.height(forWidth: width) ?? 0)
            }
            return host
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
