import os
import SciaCore
import SwiftUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var session: SessionController?
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
        session?.enterForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        logger.info("scene didEnterBackground")
        session?.enterBackground()
    }

    func showTimeline(for credential: Credential) {
        session?.stop()
        let session = SessionController(credential: credential) { [weak self] session, message in
            // ログインし直した後に古い画面の401が届いても、新しい認証情報を消さない。
            guard let self, session === self.session else { return }
            self.logOut(message: message)
        }
        self.session = session
        window?.rootViewController = session.rootViewController
        session.start()
    }

    /// 端末の認証情報を消してログイン画面に戻る。サーバー側のトークンは失効させない。
    func logOut(message: String?) {
        session?.stop()
        session = nil
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
