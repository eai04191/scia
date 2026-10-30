import Foundation
import SciaCore
import UIKit

/// ブックマークやお気に入りの画面を組み立て、読み込みを受け持つ`SavedStatusesModel`とTimelineViewControllerをつなぐ。決まりはdocs/tabs.mdの「ブックマークとお気に入り」にある。
@MainActor
final class SavedStatusesController {
    private(set) lazy var viewController = TimelineViewController(texts: Self.texts(for: kind)) { [weak model] in await model?.refresh() }
    /// 読み込みを受け持つ。
    let model: SavedStatusesModel
    var kind: SavedStatusesKind { model.kind }
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { model.runningTaskCount }

    init(kind: SavedStatusesKind, client: MastodonClient, tasks: TaskScope, onUnauthorized: @escaping () -> Void) {
        model = SavedStatusesModel(kind: kind, client: client, tasks: tasks, onUnauthorized: onUnauthorized)
        model.display = viewController
        viewController.filterWarnings = FilterWarnings(filtering: model.filtering)
        viewController.onApproachingEnd = { [weak model] in model?.approachEnd() }
        viewController.onRetry = { [weak model] in model?.retry() }
        viewController.onGapSelect = { [weak model] id, direction in model?.selectGap(id, from: direction) }
        // 開くまで読まない。開いたことのない一覧のために、起動のたびに通信しないため。
        viewController.onAppearing = { [weak model] in model?.startIfNeeded() }
    }

    private static func texts(for kind: SavedStatusesKind) -> TimelineViewController.Texts {
        switch kind {
        case .bookmarks: .bookmarks
        case .favourites: .favourites
        }
    }

    func startIfNeeded() {
        model.startIfNeeded()
    }

    #if DEBUG
    /// 始めている一覧だけ読み込み直す。障害を起こすデバッグURLで、開いたことのない一覧まで読み始めないようにする。
    func reloadIfStarted() {
        model.reloadIfStarted()
    }
    #endif

    /// タブで見せ始めたか、見せなくなったかを伝える。
    func setShown(_ shown: Bool) {
        model.setShown(shown)
    }

    /// バックグラウンドから戻ったときに呼ぶ。
    func enterForeground() {
        model.enterForeground()
    }

    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。
    func recover() {
        model.recover()
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。セッションを閉じたときは、呼ばなくても持ち主が閉じて止まる。
    func stop() {
        model.stop()
    }

    /// アプリの中で付け外しした操作を、サーバーが受け付けたときに呼ぶ。
    func statusDidSettle(_ action: StatusInteractions.Action, _ status: Status) {
        model.statusDidSettle(action, status)
    }

    /// 投稿の中身を変える。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        model.updateStatus(id, transform)
    }

    /// 削除した投稿を除く。
    func removeStatus(_ id: Status.ID) {
        model.removeStatus(id)
    }

    /// ミュートかブロックした相手の投稿を除く。
    func setAccount(_ id: String, excluded: Bool) {
        model.setAccount(id, excluded: excluded)
    }
}
