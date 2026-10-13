import SciaCore
import UIKit

/// ログイン中のアカウントの画面一式。タブの組み立てと、各タブの読み込みと接続の寿命をまとめる。
@MainActor
final class SessionController {
    let rootViewController: UIViewController
    private let home: HomeTimelineController
    private let notifications: NotificationsController

    /// - Parameter onUnauthorized: トークンが無効だったとき、どのセッションからの通知かを添えて呼ぶ。
    init(credential: Credential, onUnauthorized: @escaping (SessionController, String) -> Void) {
        let client = MastodonClient(credential: credential, transport: URLSessionTransport())
        let streaming = StreamingClient(credential: credential, connector: URLSessionWebSocketConnector())
        var report: (String) -> Void = { _ in }
        home = HomeTimelineController(client: client, streaming: streaming) { _, message in report(message) }
        notifications = NotificationsController(client: client, streaming: streaming) { _, message in report(message) }

        let homeNavigation = UINavigationController(rootViewController: home.viewController)
        let notificationsNavigation = UINavigationController(rootViewController: notifications.viewController)
        let notificationsTab = UITab(title: "通知", image: UIImage(systemName: "bell"), identifier: "notifications") { _ in notificationsNavigation }
        notifications.onUnreadCountChange = { count, isLowerBound in
            notificationsTab.badgeValue = count == 0 ? nil : isLowerBound ? "\(count)+" : "\(count)"
        }
        rootViewController = UITabBarController(tabs: [
            UITab(title: "ホーム", image: UIImage(systemName: "house"), identifier: "home") { _ in homeNavigation },
            notificationsTab,
        ])
        report = { [weak self] message in
            guard let self else { return }
            onUnauthorized(self, message)
        }
    }

    func start() {
        home.start()
        notifications.start()
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときに呼ぶ。
    func stop() {
        home.stop()
        notifications.stop()
    }

    func enterForeground() {
        home.enterForeground()
        notifications.enterForeground()
    }

    func enterBackground() {
        home.enterBackground()
        notifications.enterBackground()
    }
}
