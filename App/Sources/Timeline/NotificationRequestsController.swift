import Foundation
import SciaCore
import UIKit

/// 保留中の通知のリストを組み立て、読み込みと受け入れ・無視を受け持つ`NotificationRequestsModel`とTimelineViewControllerをつなぐ。
/// 画面は人のリストと同じくpushで開く。決まりはdocs/notification-filter.mdにある。
/// 画面がこのコントローラーを持ち、閉じて画面が捨てられたら、このコントローラーも捨てられる。
@MainActor
final class NotificationRequestsController {
    private(set) weak var viewController: TimelineViewController?
    let model: NotificationRequestsModel

    /// - Parameter openPolicy: 右上のボタンで、通知のフィルタリングの設定を開く。
    static func make(client: MastodonClient, tasks: TaskScope, openPolicy: @escaping () -> Void) -> (NotificationRequestsController, TimelineViewController) {
        let model = NotificationRequestsModel(client: client, tasks: tasks)
        let viewController = TimelineViewController(texts: .notificationRequests) { [weak model] in await model?.refresh() }
        let controller = NotificationRequestsController(model: model, viewController: viewController)
        viewController.lifetimeOwner = controller
        let item = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"), primaryAction: UIAction { _ in openPolicy() })
        item.accessibilityLabel = "通知のフィルタリング"
        viewController.screenBarItems = [item]
        return (controller, viewController)
    }

    private init(model: NotificationRequestsModel, viewController: TimelineViewController) {
        self.model = model
        self.viewController = viewController
        model.display = viewController
        viewController.onApproachingEnd = { [weak model] in model?.approachEnd() }
        viewController.onRetry = { [weak model] in model?.retry() }
        viewController.onNotificationRequestDecision = { [weak model] decision, request in model?.answer(request, decision) }
    }
}

/// 保留中の通知の1人分の、その人からの通知を組み立てる。右上に「受け入れる」と「無視」を置き、済んだら保留中の通知の画面に戻る。
/// 画面がこのコントローラーを持つ。
@MainActor
final class AccountNotificationsController {
    private(set) weak var viewController: TimelineViewController?
    let model: AccountNotificationsModel

    /// - Parameter answer: 受け入れるか無視するかを送る。済んだらtrueを返す。
    static func make(
        request: NotificationRequest,
        client: MastodonClient,
        tasks: TaskScope,
        answer: @escaping (NotificationRequestDecision) async -> Bool
    ) -> (AccountNotificationsController, TimelineViewController) {
        let model = AccountNotificationsModel(accountID: request.account.id, client: client, tasks: tasks)
        let viewController = TimelineViewController(texts: .accountNotifications(name: request.account.displayNameOrUsername)) { [weak model] in await model?.refresh() }
        let controller = AccountNotificationsController(model: model, viewController: viewController)
        viewController.lifetimeOwner = controller
        viewController.navigationItem.subtitle = "@\(request.account.acct)"
        // `rightBarButtonItems`は右から並ぶため、受け入れるが右に来る。
        viewController.screenBarItems = [NotificationRequestDecision.accept, .dismiss].map { decision in
            barItem(for: decision) { [weak viewController] in
                Task(.action) { @MainActor in
                    guard await answer(decision), let viewController, let navigation = viewController.navigationController else { return }
                    // 待つ間に、この画面の上に別の画面（スレッドなど）を開いていたら、その画面は閉じずに、この画面だけを積みから外す。
                    if navigation.topViewController === viewController {
                        navigation.popViewController(animated: true)
                    } else {
                        navigation.setViewControllers(navigation.viewControllers.filter { $0 !== viewController }, animated: false)
                    }
                }
            }
        }
        return (controller, viewController)
    }

    private init(model: AccountNotificationsModel, viewController: TimelineViewController) {
        self.model = model
        self.viewController = viewController
        model.display = viewController
        viewController.filterWarnings = FilterWarnings(filtering: model.filtering)
        viewController.onApproachingEnd = { [weak model] in model?.approachEnd() }
        viewController.onRetry = { [weak model] in model?.retry() }
    }

    /// 文字のボタンにすると見出しが押し出されて消えるため、Mastodonのwebと同じくアイコンにし、読み上げに名前を付ける。
    private static func barItem(for decision: NotificationRequestDecision, _ perform: @escaping () -> Void) -> UIBarButtonItem {
        switch decision {
        case .accept:
            let item = UIBarButtonItem(image: UIImage(systemName: "checkmark"), primaryAction: UIAction { _ in perform() })
            item.style = .prominent
            item.accessibilityLabel = "受け入れる"
            return item
        case .dismiss:
            let item = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in perform() })
            item.accessibilityLabel = "無視"
            return item
        }
    }

    func removeNotification(_ notification: MastodonNotification) {
        model.removeNotification(notification)
    }

    func setTag(_ name: String, excluded: Bool) {
        model.setTag(name, excluded: excluded)
    }

    func setAccount(_ id: String, excluded: Bool) {
        model.setAccount(id, excluded: excluded)
    }

    func removeFollowRequests(answering request: MastodonNotification) {
        model.removeFollowRequests(answering: request)
    }
}
