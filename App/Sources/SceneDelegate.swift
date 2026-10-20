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
        window.useAppLanguage()
        MediaDynamicRangeTraits.follow(window, settings: AppDependencies.settings, { $0.mediaDynamicRange }) { window, range in
            window.traitOverrides.imageDynamicRange = range
        }
        self.window = window
        #if DEBUG
        if let scenario = ScenarioMode.server {
            showTimeline(for: scenario.script.credential)
            ScenarioHeartbeat.start()
            ScenarioSignals.listen(for: ScenarioMode.signalPaths) { [weak self] path in
                guard let url = URL(string: "\(DebugURL.scheme)://\(path)"), let debugURL = DebugURL(url) else { return }
                self?.session?.handle(debugURL)
            }
        } else {
            showSavedAccount()
        }
        #else
        showSavedAccount()
        #endif
        window.makeKeyAndVisible()
        installNoticeOverlay()
        #if DEBUG
        EDRHeadroomOverlay.follow(window, tuning: AppDependencies.tuning)
        #endif
        // 閉じていたアプリをURLで開いたとき。プロフィールは最初の読み込みを待たずに開ける。
        for context in connectionOptions.urlContexts {
            guard let url = AppURL(context.url), let session = self.session else { continue }
            session.open(url)
        }
        #if DEBUG
        // ダミーのセッションは、閉じていたアプリをURLで開いたときも入る。
        if connectionOptions.urlContexts.contains(where: { DebugURL($0.url) == .dummySession }) {
            openDummySession()
        }
        #endif
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
            // ダミーのセッションは、ログイン画面からも入れるよう、セッションがなくても受け付ける。
            if case .dummySession = url {
                logger.info("debug url: \(context.url.absoluteString, privacy: .public)")
                openDummySession()
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

    #if DEBUG
    /// ログインせずに、ダミーのデータでホームと通知の画面に入る。Keychainのアカウントとは結び付けない。
    /// ログイン済みのときは入らない。表示だけダミーになると、アカウントのメニューの切り替えやログアウトが、保存してあるアカウントに効いてしまうため。
    private func openDummySession() {
        guard session == nil else {
            logger.error("dummy session ignored: already logged in")
            return
        }
        showTimeline(for: DummyServer.credential)
    }
    #endif

    func sceneDidBecomeActive(_ scene: UIScene) {
        logger.info("scene didBecomeActive")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        logger.info("scene willEnterForeground")
        UserAction.enterForeground.record()
        session?.enterForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        logger.info("scene didEnterBackground")
        UserAction.enterBackground.record()
        session?.enterBackground()
    }

    /// Keychainに保存したアカウントのタイムラインを出す。なければログイン画面を出す。
    private func showSavedAccount() {
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
    }

    func showTimeline(for credential: Credential) {
        session?.stop()
        let session = SessionController(credential: credential, accountMenu: { [weak self] in
            self?.makeAccountMenu() ?? UIMenu()
        }, onReauthenticate: { [weak self] session in
            guard let self, session === self.session else { return }
            await self.reauthenticate(session.credential)
        })
        self.session = session
        window?.rootViewController = session.rootViewController
        installNoticeOverlay()
        session.start()
    }

    /// アプリ内通知のチップの列を、根の画面のすぐ上に重ねる。根の画面を替えると、その上に新しい画面が載るため、重ね直す。
    private func installNoticeOverlay() {
        guard let window else { return }
        if let session {
            NoticeOverlay.install(in: window, center: session.notices)
        } else {
            NoticeOverlay.remove(from: window)
        }
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
            self?.window?.rootViewController?.frontmostPresented.presentSettings(
                loadPreviewAccount: { try await session.myAccount() },
                instance: session.credential.instance,
                diagnostics: session.diagnostics
            )
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
    /// 揃えないと、別のシーンが古いアカウントや、ログインし直す前の古いトークンのまま投稿したりするため。
    private static func syncAllScenes() {
        for scene in UIApplication.shared.connectedScenes {
            (scene.delegate as? SceneDelegate)?.showCurrentAccount()
        }
    }

    /// 選んでいるアカウントの画面にする。すでにそのアカウントの画面なら何もしない。アカウントがなければログイン画面にする。
    /// ログインし直してトークンが変わったときは、同じアカウントでも作り直す。
    private func showCurrentAccount() {
        guard let current = accounts?.current else {
            // すでにログイン画面なら作り直さない。出しているエラーの文言を消さないため。
            guard session != nil else { return }
            session?.stop()
            session = nil
            showLogin(errorMessage: nil)
            return
        }
        guard session?.credential != current else { return }
        showTimeline(for: current)
    }

    /// トークンが無効になったアカウントに、ログインし直す。ログイン画面は挟まず、そのアカウントのサーバーの認可画面を出す。
    /// 別のアカウントでログインされたら、そのアカウントは加えない。ログインし直しのつもりで、アカウントが増えたり切り替わったりしないようにするため。
    /// ログインし直している間に、使うアカウントが変わったら、結果を捨てる。
    private func reauthenticate(_ credential: Credential) async {
        guard let window, let accounts else { return }
        let authenticator = WebAuthenticator(anchor: window)
        do {
            let renewed = try await AppDependencies.oauth.login(instance: credential.instance) { url in
                try await authenticator.authenticate(url: url, callbackScheme: AppDependencies.oauthCallbackScheme)
            }
            guard renewed.id == credential.id else {
                throw DifferentAccountLoggedIn(expected: credential.handle, actual: renewed.handle)
            }
            // ログインし直している間に、別のシーンでログアウトや切り替えをしていたら、結果を捨てる。
            // 加えると、消したアカウントが戻ったり、切り替えたアカウントから戻ったりするため。
            guard accounts.current?.id == credential.id else {
                logger.info("reauthentication discarded: account changed")
                return
            }
            try accounts.add(renewed)
            logger.info("account reauthenticated")
            Self.syncAllScenes()
        } catch is CancellationError {
            logger.info("reauthentication cancelled")
        } catch {
            logger.error("reauthentication failed: \(SciaLog.describe(error), privacy: .public)")
            let alert = UIAlertController(title: "ログインし直せませんでした", message: ErrorPresentation(error).text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            window.rootViewController?.frontmostPresented.present(alert, animated: true)
        }
    }

    /// ログイン画面をシートで出し、ログインできたらそのアカウントに切り替える。
    /// キャンセルした後にログインの続きが終わっても、アカウントは加えない。閉じたのに別のアカウントへ切り替わらないようにするため。
    private func presentAddAccount() {
        guard let presenter = window?.rootViewController?.frontmostPresented else { return }
        weak var sheet: UIViewController?
        let attempt = AddAccountAttempt()
        let model = LoginModel(accountDomains: accountDomains) { [weak self] credential in
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
        guard let presenter = window?.rootViewController?.frontmostPresented, let current = accounts?.current else { return }
        let alert = UIAlertController(
            title: "\(current.handle)からログアウトしますか？",
            message: "この端末からアカウントの情報を消します。もう一度使うにはログインし直します。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "ログアウト", style: .destructive) { [weak self] _ in
            self?.logOut(current)
        })
        presenter.present(alert, animated: true)
    }

    /// アカウントの情報を端末から消す。ほかにアカウントがあればそちらに切り替え、なければログイン画面に戻る。
    /// サーバー側のトークンは失効させない。使う人がログアウトを選んだときだけ呼ぶ。APIの応答を理由には呼ばない。
    private func logOut(_ credential: Credential) {
        guard let accounts else {
            showCurrentAccount()
            return
        }
        do {
            try accounts.remove(credential.id)
        } catch {
            showLogin(errorMessage: error.localizedDescription)
            return
        }
        logger.info("account removed")
        showCurrentAccount()
        Self.syncAllScenes()
    }

    /// ログイン画面の候補の上に出す、ログイン済みのアカウントのサーバー。
    private var accountDomains: [String] {
        accounts?.accounts.compactMap { ServerSuggestions.address(of: $0.instance) } ?? []
    }

    func showLogin(errorMessage: String?) {
        let model = LoginModel(accountDomains: accountDomains) { [weak self] credential in
            guard let accounts = self?.accounts else {
                throw AccountsUnavailable()
            }
            try accounts.add(credential)
            Self.syncAllScenes()
        }
        #if DEBUG
        let onDummySession: (@MainActor () -> Void)? = { [weak self] in self?.openDummySession() }
        #else
        let onDummySession: (@MainActor () -> Void)? = nil
        #endif
        let view = LoginView(
            model: model,
            makeAuthenticator: { [weak self] in self?.window.map { WebAuthenticator(anchor: $0) } },
            onDummySession: onDummySession
        )
        window?.rootViewController = UIHostingController(rootView: view)
        installNoticeOverlay()
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

/// ログインし直しで、元とは別のアカウントでログインされた。
private struct DifferentAccountLoggedIn: LocalizedError {
    let expected: String
    let actual: String

    var errorDescription: String? {
        "\(actual)でログインされました。\(expected)でログインし直してください。"
    }
}

/// 起動時にKeychainを読めず、アカウントを保存できない。
private struct AccountsUnavailable: LocalizedError {
    var errorDescription: String? {
        "アカウントの情報を読み書きできません。アプリを起動し直してください。"
    }
}
