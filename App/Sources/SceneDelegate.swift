import os
import SciaCore
import SwiftUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
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

    func sceneDidEnterBackground(_ scene: UIScene) {
        logger.info("scene didEnterBackground")
    }

    func showTimeline(for credential: Credential) {
        window?.rootViewController = UINavigationController(rootViewController: TimelineViewController())
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
