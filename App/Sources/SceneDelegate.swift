import os
import SciaCore
import SwiftUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var homeTimeline: HomeTimelineController?
    private var notifications: NotificationsController?
    private let logger = SciaLog.logger(category: "lifecycle")

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        logger.info("scene willConnect")
        let window = ShakeDetectingWindow(windowScene: windowScene)
        self.window = window
        do {
            if let credential = try AppDependencies.credentials.load() {
                showTimeline(for: credential)
            } else {
                showLogin(errorMessage: nil)
            }
        } catch {
            logger.error("credential load failed: \(error.localizedDescription, privacy: .public)")
            showLogin(errorMessage: error.localizedDescription)
        }
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        logger.info("scene didBecomeActive")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        logger.info("scene willEnterForeground")
        homeTimeline?.enterForeground()
        notifications?.enterForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        logger.info("scene didEnterBackground")
        homeTimeline?.enterBackground()
        notifications?.enterBackground()
    }

    func showTimeline(for credential: Credential) {
        stopTimelines()
        let client = MastodonClient(credential: credential, transport: URLSessionTransport())
        let streaming = StreamingClient(credential: credential, connector: URLSessionWebSocketConnector())
        let home = HomeTimelineController(client: client, streaming: streaming) { [weak self] controller, message in
            // ログインし直した後に古い画面の401が届いても、新しい認証情報を消さない。
            guard let self, controller === self.homeTimeline else { return }
            self.logOut(message: message)
        }
        let notifications = NotificationsController(client: client, streaming: streaming) { [weak self] controller, message in
            guard let self, controller === self.notifications else { return }
            self.logOut(message: message)
        }
        homeTimeline = home
        self.notifications = notifications

        let homeNavigation = UINavigationController(rootViewController: home.viewController)
        let notificationsNavigation = UINavigationController(rootViewController: notifications.viewController)
        let notificationsTab = UITab(title: "通知", image: UIImage(systemName: "bell"), identifier: "notifications") { _ in notificationsNavigation }
        notifications.onUnreadCountChange = { count, isLowerBound in
            notificationsTab.badgeValue = count == 0 ? nil : isLowerBound ? "\(count)+" : "\(count)"
        }
        window?.rootViewController = UITabBarController(tabs: [
            UITab(title: "ホーム", image: UIImage(systemName: "house"), identifier: "home") { _ in homeNavigation },
            notificationsTab,
        ])
        home.start()
        notifications.start()
    }

    private func stopTimelines() {
        homeTimeline?.stop()
        homeTimeline = nil
        notifications?.stop()
        notifications = nil
    }

    /// 端末の認証情報を消してログイン画面に戻る。サーバー側のトークンは失効させない。
    func logOut(message: String?) {
        stopTimelines()
        do {
            try AppDependencies.credentials.delete()
            showLogin(errorMessage: message)
        } catch {
            showLogin(errorMessage: error.localizedDescription)
        }
    }

    func showLogin(errorMessage: String?) {
        let model = LoginModel { [weak self] credential in
            self?.showTimeline(for: credential)
        }
        let view = LoginView(model: model) { [weak self] in
            self?.window.map { WebAuthenticator(anchor: $0) }
        }
        window?.rootViewController = UIHostingController(rootView: view)
        if let errorMessage {
            model.showError(errorMessage)
        }
    }
}
