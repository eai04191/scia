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
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // Macで縦長のウィンドウに並べられるよう、最小幅を今のiPhoneで一番狭い幅まで下げる
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 375, height: 480)
        }
        let window = ShakeDetectingWindow(windowScene: windowScene)
        self.window = window
        switch AppDependencies.accounts {
        case .success(let accounts):
            if let credential = accounts.current {
                showTimeline(for: credential)
            } else {
                showLogin(errorMessage: nil)
            }
        case .failure(let error):
            logger.error("credential load failed: \(error.localizedDescription, privacy: .public)")
            showLogin(errorMessage: error.localizedDescription)
        }
        window.makeKeyAndVisible()
        // 閉じていたアプリをURLで開いたとき。プロフィールは最初の読み込みを待たずに開ける。
        for context in connectionOptions.urlContexts {
            guard let url = AppURL(context.url), let session = self.session else { continue }
            session.open(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        open(URLContexts)
    }

    /// 他のアプリから開かれたURLを処理する。ログインしていなければ何もしない。
    private func open(_ URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            guard let url = AppURL(context.url) else { continue }
            guard let session else {
                logger.error("url ignored without session: \(context.url.absoluteString, privacy: .public)")
                continue
            }
            logger.info("open url: \(context.url.absoluteString, privacy: .public)")
            session.open(url)
        }
        #if DEBUG
        openDebug(URLContexts)
        #endif
    }

    #if DEBUG
    /// 起動済みのアプリに届いたデバッグ用のURLを処理する。
    /// 起動時のURL（`connectionOptions.urlContexts`）は扱わない。最初の読み込みの前にダミーを流すと、読み込んだ投稿との並びを確かめられないため。
    private func openDebug(_ URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts where AppURL(context.url) == nil {
            guard let url = DebugURL(context.url) else {
                logger.error("unknown debug url: \(context.url.absoluteString, privacy: .public)")
                continue
            }
            guard let session else {
                logger.error("debug url ignored without session: \(context.url.absoluteString, privacy: .public)")
                continue
            }
            logger.info("debug url: \(context.url.absoluteString, privacy: .public)")
            session.handle(url)
        }
    }
    #endif

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
        let session = SessionController(credential: credential, accountMenu: { [weak self] in
            self?.makeAccountMenu() ?? UIMenu()
        }, onUnauthorized: { [weak self] session, message in
            // ログインし直した後や切り替えた後に古い画面の401が届いても、いま使っているアカウントを消さない。
            guard let self, session === self.session else { return }
            self.logOut(session.credential, message: message)
        })
        self.session = session
        window?.rootViewController = session.rootViewController
        session.start()
    }

    // MARK: - アカウント

    private var accounts: AccountRegistry? {
        try? AppDependencies.accounts.get()
    }

    /// アカウントの一覧、追加、ログアウトのメニュー。開くたびに今のアカウントで組み立て直す。
    private func makeAccountMenu() -> UIMenu {
        guard let accounts else { return UIMenu() }
        let switching = accounts.accounts.map { account in
            UIAction(title: account.handle, state: account.id == accounts.current?.id ? .on : .off) { [weak self] _ in
                self?.switchAccount(to: account.id)
            }
        }
        let add = UIAction(title: "アカウントを追加", image: UIImage(systemName: "person.badge.plus")) { [weak self] _ in
            self?.presentAddAccount()
        }
        let settings = UIAction(title: "設定", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            guard let session = self?.session else { return }
            self?.window?.rootViewController?.presentSettings { try await session.myAccount() }
        }
        let logOut = UIAction(title: "ログアウト", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) { [weak self] _ in
            self?.confirmLogOut()
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: switching),
            add,
            UIMenu(options: .displayInline, children: [settings]),
            UIMenu(options: .displayInline, children: [logOut]),
        ])
    }

    private func switchAccount(to id: Credential.ID) {
        guard let accounts, accounts.current?.id != id else { return }
        accounts.select(id)
        logger.info("account switched")
        Self.syncAllScenes()
    }

    /// 選んでいるアカウントはシーンをまたいで1つなので、変えたらすべてのシーンの画面をそれに揃える。
    /// 揃えないと、別のシーンが古いアカウントのまま投稿したり、そのアカウントの失効で選んでいるアカウントを消したりするため。
    private static func syncAllScenes() {
        for scene in UIApplication.shared.connectedScenes {
            (scene.delegate as? SceneDelegate)?.showCurrentAccount()
        }
    }

    /// 選んでいるアカウントの画面にする。すでにそのアカウントの画面なら何もしない。アカウントがなければログイン画面にする。
    private func showCurrentAccount(message: String? = nil) {
        guard let current = accounts?.current else {
            // すでにログイン画面なら作り直さない。出しているエラーの文言を消さないため。
            guard session != nil else { return }
            session?.stop()
            session = nil
            showLogin(errorMessage: message)
            return
        }
        guard session?.credential.id != current.id else { return }
        showTimeline(for: current)
    }

    /// ログイン画面をシートで出し、ログインできたらそのアカウントに切り替える。
    /// キャンセルした後にログインの続きが終わっても、アカウントは加えない。閉じたのに別のアカウントへ切り替わらないようにするため。
    private func presentAddAccount() {
        guard let presenter = window?.rootViewController else { return }
        weak var sheet: UIViewController?
        let attempt = AddAccountAttempt()
        let model = LoginModel { [weak self] credential in
            guard !attempt.isCancelled else { return }
            try self?.accounts?.add(credential)
            sheet?.dismiss(animated: true)
            Self.syncAllScenes()
        }
        let view = LoginView(model: model, makeAuthenticator: { [weak self] in
            self?.window.map { WebAuthenticator(anchor: $0) }
        }, onCancel: {
            attempt.isCancelled = true
            sheet?.dismiss(animated: true)
        })
        let hosting = UIHostingController(rootView: view)
        // 下へのスワイプで閉じると、キャンセルとして扱えないため、閉じるのはキャンセルボタンだけにする。
        hosting.isModalInPresentation = true
        sheet = hosting
        presenter.present(hosting, animated: true)
    }

    private func confirmLogOut() {
        guard let presenter = window?.rootViewController, let current = accounts?.current else { return }
        let alert = UIAlertController(
            title: "\(current.handle)からログアウトしますか？",
            message: "この端末からアカウントの情報を消します。もう一度使うにはログインし直します。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "ログアウト", style: .destructive) { [weak self] _ in
            self?.logOut(current, message: nil)
        })
        presenter.present(alert, animated: true)
    }

    /// アカウントの情報を端末から消す。ほかにアカウントがあればそちらに切り替え、なければログイン画面に戻る。
    /// サーバー側のトークンは失効させない。
    private func logOut(_ credential: Credential, message: String?) {
        guard let accounts else {
            showCurrentAccount(message: message)
            return
        }
        do {
            try accounts.remove(credential.id)
        } catch {
            showLogin(errorMessage: error.localizedDescription)
            return
        }
        logger.info("account removed")
        showCurrentAccount(message: message)
        Self.syncAllScenes()
        if let message, accounts.current != nil {
            let alert = UIAlertController(title: "\(credential.handle)からログアウトしました", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            window?.rootViewController?.present(alert, animated: true)
        }
    }

    func showLogin(errorMessage: String?) {
        let model = LoginModel { [weak self] credential in
            guard let accounts = self?.accounts else {
                throw AccountsUnavailable()
            }
            try accounts.add(credential)
            Self.syncAllScenes()
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

/// アカウントを追加する操作。キャンセルしたかを、ログインの続きから確かめる。
@MainActor
private final class AddAccountAttempt {
    var isCancelled = false
}

/// 起動時にKeychainを読めず、アカウントを保存できない。
private struct AccountsUnavailable: LocalizedError {
    var errorDescription: String? {
        "アカウントの情報を読み書きできません。アプリを起動し直してください。"
    }
}
