import SciaCore
import UIKit

/// スレッドの画面を組み立て、読み込みとストリーミングを受け持つ`ThreadModel`とTimelineViewControllerをつなぐ。
/// 画面を開く動きとの間合い（移り終わってから行を足す、開くために空けた余白を戻す、押した投稿を持ち上げる）は、ここで受け持つ。
///
/// 画面はナビゲーションに積まれて閉じられるまで生きるため、画面の方がこのコントローラーを持つ。
@MainActor
final class ThreadController {
    private(set) weak var viewController: TimelineViewController?
    /// 読み込みとストリーミングを受け持つ。
    let model: ThreadModel

    static func make(
        focus: Status,
        client: MastodonClient,
        streamingHub: StreamingHub,
        tasks: TaskScope,
        onUnauthorized: @escaping () -> Void
    ) -> (ThreadController, TimelineViewController) {
        let model = ThreadModel(focus: focus, client: client, streamingHub: streamingHub, tasks: tasks, onUnauthorized: onUnauthorized)
        let viewController = TimelineViewController(texts: .thread) { [weak model] in await model?.refresh() }
        let controller = ThreadController(model: model, focusID: focus.id, viewController: viewController)
        viewController.lifetimeOwner = controller
        return (controller, viewController)
    }

    private init(model: ThreadModel, focusID: Status.ID, viewController: TimelineViewController) {
        self.model = model
        self.viewController = viewController
        model.display = viewController
        viewController.filterWarnings = FilterWarnings(filtering: model.filtering)
        viewController.threadFocusID = focusID
        viewController.hidesReplyLabelBelowParent = true
        viewController.onRetry = { [weak model] in model?.retry() }
        model.afterTransition = { [weak viewController] work in
            // 画面を移る動きの最中なら、移り終わってから行う。移る途中に行を足すと、メインスレッドが止まって動きが跳ぶため。
            guard let coordinator = viewController?.transitionCoordinator else {
                work()
                return
            }
            coordinator.animate(alongsideTransition: nil) { _ in work() }
        }
        model.onFirstLoadShown = { [weak viewController] in
            guard let viewController else { return }
            viewController.releaseOpeningInset()
            if viewController.tuning.value(of: TuningCatalog.threadRaisesFocusedPost) {
                viewController.raiseIfNextRowHidden(.status(focusID))
            }
        }
    }

    /// 走り終えていない処理の数。閉じたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { model.runningTaskCount }

    var focusID: Status.ID { model.focusID }

    var loadTask: Task<Void, Never>? { model.loadTask }

    /// 画面に積む前に呼ぶ。押した投稿だけを並べ、会話を読み始める。
    func start() {
        model.start()
    }

    /// 投稿への操作の結果を反映する。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        model.updateStatus(id, transform)
    }

    /// 削除した投稿を除く。
    func removeStatus(_ id: Status.ID) {
        model.removeStatus(id)
    }

    /// 投稿欄から送った投稿を、ストリーミングで届くのを待たずに足す。
    func receivePosted(_ status: Status) {
        model.receivePosted(status)
    }

    /// バックグラウンドに入るときに呼ぶ。
    func enterBackground() {
        model.enterBackground()
    }

    /// バックグラウンドから戻ったときに呼ぶ。
    func enterForeground() {
        model.enterForeground()
    }
}
