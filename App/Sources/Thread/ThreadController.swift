import SciaCore
import UIKit

/// スレッドの画面を組み立て、読み込みとストリーミングを受け持つ`ThreadModel`とTimelineViewControllerをつなぐ。
/// 画面を開く動きとの間合い（遷移し終わってから行を足す、開くために空けた余白を戻す、選択した投稿を持ち上げる）は、ここで受け持つ。
///
/// 画面はナビゲーションにプッシュされて閉じられるまで生きるため、画面の方がこのコントローラーを持つ。
@MainActor
final class ThreadController {
    private(set) weak var viewController: TimelineViewController?
    let model: ThreadModel

    static func make(
        focus: Status,
        client: MastodonClient,
        streamingHub: StreamingHub,
        settings: AppSettings,
        tasks: TaskScope
    ) -> (ThreadController, TimelineViewController) {
        let model = ThreadModel(focus: focus, client: client, streamingHub: streamingHub, tasks: tasks)
        let viewController = TimelineViewController(texts: .thread, settings: settings) { [weak model] in await model?.refresh() }
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
            // 画面遷移の最中なら、遷移し終わってから行う。遷移の途中に行を足すと、メインスレッドが止まって動きが跳ぶため。
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

    /// 画面にプッシュする前に呼ぶ。選択した投稿だけを並べ、会話を読み始める。
    func start() {
        model.start()
    }

    func enterBackground() {
        model.enterBackground()
    }

    func enterForeground() {
        model.enterForeground()
    }
}
