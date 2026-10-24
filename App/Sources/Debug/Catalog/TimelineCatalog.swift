#if DEBUG
import Foundation
import SciaCore
import UIKit

/// タイムラインの、投稿のほかに出す表示の状態。読み込みの失敗はサーバーで起こさず、本物と同じ変換（`ErrorPresentation(_:)`）を通したエラーで出す。
enum TimelineCatalog {
    private static let offline = ErrorPresentation(URLError(.notConnectedToInternet))
    private static let badGateway = ErrorPresentation(MastodonAPIError(statusCode: 502, message: "Bad Gateway"))
    private static let tooManyRequests = ErrorPresentation(MastodonAPIError(statusCode: 429, message: "Too Many Requests"))

    /// 投稿が1件もないときに一覧の全面に出す表示。
    @MainActor
    static func emptyStates() -> [CatalogState] {
        let home = TimelineViewController(texts: .home, refresh: {})
        let notifications = TimelineViewController(texts: .notifications, refresh: {})
        func state(_ title: String, _ controller: TimelineViewController, _ state: TimelineViewController.ContentState) -> CatalogState {
            CatalogState(title: title) {
                CatalogFrame.bordered(UIContentUnavailableView(configuration: controller.contentUnavailableConfiguration(for: state)), height: 280)
            }
        }
        return [
            state("読み込み中", home, .loading),
            state("ホームに投稿がない", home, .loaded),
            state("通知がない", notifications, .loaded),
            state("サーバーがホームを作り直している", home, .regenerating),
            state("インターネットに接続できない", home, .failed(offline)),
            state("サーバーが応答できない（HTTP 502）", home, .failed(badGateway)),
            state("リクエストが多すぎて止められた（HTTP 429）", home, .failed(tooManyRequests)),
        ]
    }

    /// 一覧の末尾で、古い投稿や通知の読み込みの状態を出す表示。
    @MainActor
    static func footerStates() -> [CatalogState] {
        func state(_ title: String, _ state: TimelineViewController.FooterState, reachedEndText: String = TimelineViewController.Texts.home.reachedEnd) -> CatalogState {
            CatalogState(title: title) {
                let footer = TimelineFooterView()
                footer.apply(state, reachedEndText: reachedEndText)
                return CatalogFrame.bordered(footer)
            }
        }
        return [
            state("読み込み中", .loading),
            state("インターネットに接続できない", .failed(offline)),
            state("サーバーが応答できない（HTTP 502）", .failed(badGateway)),
            state("リクエストが多すぎて止められた（HTTP 429）", .failed(tooManyRequests)),
            state("ホームの末尾まで読んだ", .reachedEnd),
            state("通知の末尾まで読んだ", .reachedEnd, reachedEndText: TimelineViewController.Texts.notifications.reachedEnd),
            state("ヘッダーのある一覧（プロフィール）に投稿がない", .reachedEnd, reachedEndText: TimelineViewController.Texts.profile.empty),
        ]
    }

    /// 投稿の代わりに出す行。
    @MainActor
    static func rowStates() -> [CatalogState] {
        let home = TimelineViewController(texts: .home, refresh: {})
        let notifications = TimelineViewController(texts: .notifications, refresh: {})
        func row(_ title: String, _ configuration: UIListContentConfiguration) -> CatalogState {
            CatalogState(title: title) { CatalogFrame.bordered(UIListContentView(configuration: configuration)) }
        }
        let base = UIListContentConfiguration.cell()
        return [
            row("読めない投稿（ブラウザで開ける）", home.unreadableContentConfiguration(for: UnreadableItem(id: "1", url: URL(string: "https://example.com/@user/1")), base: base)),
            row("読めない通知（開ける先がない）", notifications.unreadableContentConfiguration(for: UnreadableItem(id: "2", url: nil), base: base)),
            row("読み込んでいない投稿がある", home.gapContentConfiguration(isLoading: false, base: base)),
            row("読み込んでいない投稿を読み込み中", home.gapContentConfiguration(isLoading: true, base: base)),
            row("読み込んでいない投稿を読み込めなかった（サーバーの失敗）", home.gapContentConfiguration(
                isLoading: false,
                failure: badGateway,
                base: base
            )),
            row("読み込んでいない投稿を読み込めなかった（レート制限、長い理由）", home.gapContentConfiguration(
                isLoading: false,
                failure: tooManyRequests,
                base: base
            )),
        ]
    }
}
#endif
