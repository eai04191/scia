import Foundation
import SciaCore
import UIKit

/// ブックマークやお気に入り、ある投稿を引用した投稿の画面を組み立て、読み込みを受け持つ`SavedStatusesModel`とTimelineViewControllerをつなぐ。決まりはdocs/tabs.mdの「ブックマークとお気に入り」にある。
@MainActor
final class SavedStatusesController {
    private(set) lazy var viewController = TimelineViewController(texts: Self.texts(for: kind)) { [weak model] in await model?.refresh() }
    /// 読み込みを受け持つ。
    let model: SavedStatusesModel
    var kind: SavedStatusesKind { model.kind }
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { model.runningTaskCount }

    init(kind: SavedStatusesKind, session: AccountSession) {
        model = SavedStatusesModel(kind: kind, session: session)
        model.display = viewController
        viewController.filterWarnings = FilterWarnings(filtering: model.filtering)
        viewController.onApproachingEnd = { [weak model] in model?.approachEnd() }
        viewController.onRetry = { [weak model] in model?.retry() }
        viewController.onGapSelect = { [weak model] id, direction in model?.selectGap(id, from: direction) }
        // 開くまで読まない。開いたことのないタイムラインのために、起動のたびに通信しないため。
        viewController.onAppearing = { [weak model] in model?.startIfNeeded() }
    }

    private static func texts(for kind: SavedStatusesKind) -> TimelineViewController.Texts {
        switch kind {
        case .bookmarks: .bookmarks
        case .favourites: .favourites
        case .quotes: .quotes
        }
    }

    func startIfNeeded() {
        model.startIfNeeded()
    }

    #if DEBUG
    /// 始めているタイムラインだけ読み込み直す。障害を起こすデバッグURLで、開いたことのないタイムラインまで読み始めないようにする。
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

    /// アプリの中で付け外しした操作を、サーバーが受け付けたときに呼ぶ。
    func statusDidSettle(_ action: StatusInteractions.Action, _ status: Status) {
        model.statusDidSettle(action, status)
    }

    /// ミュートかブロックした相手の投稿を除く。
    func setAccount(_ id: String, excluded: Bool) {
        model.setAccount(id, excluded: excluded)
    }
}
