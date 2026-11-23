import os
import SciaCore
import SwiftUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var windowSettings: WindowSettings?
    /// ウィンドウに出しているアカウントの画面一式。替えたり外したりしたら、前のセッションで始めた処理を止める。
    /// ログアウト、アカウントの切り替え、ログイン画面に戻す、ウィンドウを閉じるのどの経路でも、ここを通れば止まる。
    private var session: SessionController? {
        didSet {
            guard oldValue !== session else { return }
            oldValue?.stop()
        }
    }
    /// ウィンドウの下書き。アカウントを替えて画面一式を作り直しても、次の画面一式に渡す（docs/compose.mdの「アカウントを変えるとき」）。
    private var draft: ComposeModel<UIImage>?
    /// 下書きの送信とアップロードの持ち主。ウィンドウを閉じたときに閉じる。
    private let draftTasks = TaskScope()
    private let logger = SciaLog.logger(category: "lifecycle")
    /// 保存したアカウントを読めずにログイン画面を出している。端末のロック中など一時的なことがあるので、前面に戻ったら読み直す。
    private var isShowingAccountsLoadFailure = false

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
        let windowSettings = WindowSettings(window: window)
        windowSettings.use(AppDependencies.settings)
        self.windowSettings = windowSettings
        self.window = window
        #if DEBUG
        if let scenario = ScenarioMode.server {
            scenario.script.configure(AppDependencies.settings, AppDependencies.tuning)
            showTimeline(for: scenario.script.credential)
            ScenarioHeartbeat.start()
            ScenarioSignals.listen(for: ScenarioMode.signalPaths) { [weak self] path in
                guard let url = URL(string: "\(DebugURL.scheme)://\(path)"), let debugURL = DebugURL(url) else { return }
                self?.session?.handle(debugURL)
            }
        } else if AppDependencies.isHostingUnitTests {
            // ユニットテストは、このアプリをホストにして同じプロセスとメインスレッドで走る。保存してあるアカウントでセッションを始めると、
            // 実サーバーとの通信とストリーミング、状態ダンプの登録、キーボードの知らせを受ける投稿欄が、テストと並んで動き、
            // 結果が端末のログインの有無やサーバーの状態、ほかのスレッドの操作に左右されるため、何も始めない。
            window.rootViewController = UIViewController()
        } else {
            showSavedAccount()
        }
        #else
        showSavedAccount()
        #endif
        window.makeKeyAndVisible()
        installNoticeOverlay()
        EDRHeadroomOverlay.follow(window, developerMode: AppDependencies.developerMode)
        // 閉じていたアプリをURLで開いたとき。プロフィールは最初の読み込みを待たずに開ける。
        for context in connectionOptions.urlContexts {
            guard let url = AppURL(context.url) else { continue }
            open(url)
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

    private func open(_ url: AppURL) {
        guard let session else {
            logger.error("url ignored without session: \(url.logDescription, privacy: .public)")
            // 共有拡張が置いたファイルは、受け取らないなら残さない。
            if case .share(let id, _) = url {
                SharedMediaInbox.app?.remove(id: id)
            }
            return
        }
        logger.info("open url: \(url.logDescription, privacy: .public)")
        session.open(url)
    }

    /// アプリの中から、このウィンドウのセッションで画面を開く。ログインしていなければ何もしない。
    func open(_ destination: AppDestination) {
        guard let session else {
            logger.error("destination ignored without session")
            return
        }
        session.open(destination)
    }

    /// 他のアプリから開かれたURLを処理する。ログインしていなければ何もしない。
    private func open(_ URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            guard let url = AppURL(context.url) else { continue }
            open(url)
        }
        #if DEBUG
        openDebug(URLContexts)
        #endif
    }

    #if DEBUG
    // デバッグ版だけで受けるURLで、agentが送った操作を追うため、ログの決まり（docs/logging.md）から外してURLを丸ごと残す。
    // scialint:disable log_private_value
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
            if case .hitAreas(let isShown) = url {
                logger.info("debug url: \(context.url.absoluteString, privacy: .public)")
                if let scene = window?.windowScene {
                    HitAreaOverlay.setShown(isShown, in: scene)
                }
                continue
            }
            if case .account(let acct) = url {
                logger.info("debug url: \(context.url.absoluteString, privacy: .public)")
                switchAccount(toHandle: acct)
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
    // scialint:enable log_private_value

    /// 保存してあるアカウントのうち、ハンドルが`acct`のものに切り替える。
    private func switchAccount(toHandle acct: String) {
        let handle = acct.hasPrefix("@") ? acct : "@" + acct
        guard let account = accounts?.accounts.first(where: { $0.handle.caseInsensitiveCompare(handle) == .orderedSame }) else {
            logger.error("debug account not found")
            return
        }
        switchAccount(to: account.id)
    }
    #endif

    #if DEBUG
    /// ダミーのセッションを選んでいるか。選んでいるアカウントと同じく、シーンをまたいで1つ。
    /// Keychainにも`AccountRegistry`にも入れないので、起動し直すと保存してあるアカウントかログイン画面に戻る。
    private static var showsDummySession = false

    /// ダミーのデータでホームと通知の画面に入る。ログイン済みでも入れ、アカウントのメニューで本物のアカウントを選ぶと戻る。
    private func openDummySession() {
        Self.showsDummySession = true
        logger.info("dummy session selected")
        Self.syncAllScenes()
    }
    #endif

    /// 本物のアカウントを選んだり加えたりしたときに、ダミーのセッションから抜ける。
    private static func leaveDummySession() {
        #if DEBUG
        showsDummySession = false
        #endif
    }

    /// ウィンドウを閉じたときや、OSが裏にいるウィンドウを手放したとき。ウィンドウの画面一式を捨て、そのセッションで始めた処理を止める。
    func sceneDidDisconnect(_ scene: UIScene) {
        logger.info("scene didDisconnect")
        session = nil
        draftTasks.close()
        #if DEBUG
        // 出したままウィンドウを閉じると、重ねたウィンドウと毎フレームの処理が残るため。
        if let scene = scene as? UIWindowScene {
            HitAreaOverlay.setShown(false, in: scene)
        }
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        logger.info("scene didBecomeActive")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        logger.info("scene willEnterForeground")
        UserAction.enterForeground.record()
        if isShowingAccountsLoadFailure {
            showSavedAccount()
        }
        session?.enterForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        logger.info("scene didEnterBackground")
        UserAction.enterBackground.record()
        session?.enterBackground()
    }

    /// Keychainに保存したアカウントのタイムラインを出す。なければログイン画面を出す。
    /// ダミーを選んでいる間に開いたシーンは、ほかのシーンに揃えてダミーにする。
    private func showSavedAccount() {
        #if DEBUG
        if Self.showsDummySession {
            showTimeline(for: DummyServer.credential)
            return
        }
        #endif
        switch AppDependencies.accounts {
        case .success(let accounts):
            if let credential = accounts.current {
                showTimeline(for: credential)
            } else {
                showLogin(errorMessage: nil)
            }
        case .failure(let error):
            logger.error("credential load failed: \(SciaLog.describe(error), privacy: .public)")
            showLogin(errorMessage: error.localizedDescription)
            isShowingAccountsLoadFailure = true
        }
    }

    func showTimeline(for credential: Credential) {
        isShowingAccountsLoadFailure = false
        var logOut: (@MainActor () -> Void)?
        if Self.canLogOut {
            logOut = { [weak self] in self?.confirmLogOut() }
        }
        let session = SessionController(credential: credential, accountMenu: { [weak self] in
            self?.makeAccountMenu() ?? UIMenu()
        }, logOut: logOut, accountManagement: accountManagement, draft: draft, draftTasks: draftTasks, onReauthenticate: { [weak self] session, credential in
            guard let self, session === self.session else { return }
            await self.reauthenticate(credential, isCurrent: credential.id == session.credential.id)
        })
        let replacesSession = self.session != nil
        let hadDraft = draft != nil
        self.session = session
        draft = session.composer.model
        // 前の画面一式を止めてからつなぎ直す。前の画面一式が、つなぎ直した下書きの変化を受けないようにするため。
        if hadDraft {
            session.rebindDraft()
        }
        windowSettings?.use(session.settings)
        // アカウントを切り替えたときは、前のアカウントの画面から薄くして入れ替える。起動したときは、ローンチ画面から切り替える。
        let duration = replacesSession ? AppDependencies.tuning.value(of: TuningCatalog.accountSwitchDuration) : 0
        if let window, duration > 0 {
            UIView.transition(with: window, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                // 新しい画面の並べ方まで動きに乗ると、左上の小さな枠から広がって見えるため、差し替えは動かさずに行い、見え方だけを入れ替える。
                UIView.performWithoutAnimation {
                    window.rootViewController = session.windowRootViewController
                    self.installNoticeOverlay()
                    window.layoutIfNeeded()
                }
            }
        } else {
            window?.rootViewController = session.windowRootViewController
            installNoticeOverlay()
        }
        session.start()
        // 裏にいるウィンドウでアカウントを切り替えたときなど。始めた時点で裏なら、前に戻るまで接続しない。戻ったときに`sceneWillEnterForeground`で始め直す。
        if window?.windowScene?.activationState == .background {
            session.enterBackground()
        }
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

    /// 「アカウントを管理」の画面で行う、アカウントの切り替え、ログアウト、追加。アカウントのメニューと同じ流れで行う。
    private var accountManagement: AccountManagement {
        AccountManagement(
            currentID: { [weak self] in self?.checkedAccountID },
            canLogOut: Self.canLogOut,
            switchTo: { [weak self] id in
                guard let self, let account = accounts?.accounts.first(where: { $0.id == id }) else { return }
                switchAccount(to: account.id)
            },
            logOut: { [weak self] id in
                guard let self, let account = accounts?.accounts.first(where: { $0.id == id }) else { return }
                confirmLogOut(account)
            },
            add: { [weak self] in self?.presentAddAccount() }
        )
    }

    /// アカウントのリストでチェックマークを付けるアカウント。ダミーを選んでいる間は、裏で選んだままの本物のアカウントに付けない。
    private var checkedAccountID: Credential.ID? {
        #if DEBUG
        if Self.showsDummySession { return nil }
        #endif
        return accounts?.current?.id
    }

    /// アカウントのリストと「アカウントを管理」のメニュー。開くたびに今のアカウントで組み立て直す。
    private func makeAccountMenu() -> UIMenu {
        guard let accounts else { return UIMenu() }
        let manage = UIAction(title: SettingsPage.accountManagement.title(), image: UIImage(systemName: "person.2.badge.gearshape")) { [weak self] _ in
            self?.session?.open(.settings(.accountManagement))
        }
        #if DEBUG
        let dummy = [UIAction(title: DummyServer.credential.handle, subtitle: "ダミーのデータ", state: Self.showsDummySession ? .on : .off) { [weak self] _ in
            self?.openDummySession()
        }]
        #else
        let dummy: [UIAction] = []
        #endif
        let checkedID = checkedAccountID
        let switching = accounts.accounts.map { account in
            UIAction(title: account.handle, state: account.id == checkedID ? .on : .off) { [weak self] _ in
                self?.switchAccount(to: account.id)
            }
        } + dummy
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: switching),
            UIMenu(options: .displayInline, children: [manage]),
        ])
    }

    /// `id`のアカウントからログアウトすると、どれかのウィンドウの下書きが捨てられるか。
    /// そのアカウントのサーバーの投稿（編集、削除して書き直す、書き直す予約）を書いている下書きは、ほかのアカウントでは続けられないため（docs/compose.mdの「アカウントを変えるとき」）。
    private static func discardsDraft(loggingOut id: Credential.ID) -> Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            guard let draft = (scene.delegate as? SceneDelegate)?.draft else { return false }
            return draft.writingAccountID == id && draft.pointsToServerPost
        }
    }

    /// ダミーを選んでいる間は、裏で選んだままのアカウントを選んでも、ダミーから抜けてそのアカウントに戻る。
    private func switchAccount(to id: Credential.ID) {
        guard let accounts else { return }
        Self.leaveDummySession()
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
        #if DEBUG
        if Self.showsDummySession {
            guard session?.credential != DummyServer.credential else { return }
            showTimeline(for: DummyServer.credential)
            return
        }
        #endif
        guard let current = accounts?.current else {
            // すでにログイン画面なら作り直さない。出しているエラーの文言を消さないため。
            guard session != nil else { return }
            showLogin(errorMessage: nil)
            return
        }
        guard session?.credential != current else { return }
        showTimeline(for: current)
    }

    /// トークンが無効になったアカウントに、ログインし直す。ログイン画面は挟まず、そのアカウントのサーバーの認可画面を出す。
    /// 別のアカウントでログインされたら、そのアカウントは加えない。ログインし直しのつもりで、アカウントが増えたり切り替わったりしないようにするため。
    /// - Parameter isCurrent: 使っているアカウントか。使っているアカウントなら、ログインし直している間に使うアカウントが変わったら、結果を捨てる。
    ///   ほかのアカウント（「別のアカウントで」で操作したアカウント）なら、使うアカウントは替えずに認証情報だけを新しくし、その間にログアウトしていたら結果を捨てる。
    private func reauthenticate(_ credential: Credential, isCurrent: Bool) async {
        guard let window, let accounts else { return }
        let authenticator = WebAuthenticator(anchor: window)
        do {
            let renewed = try await AppDependencies.oauth.login(instance: credential.instance) { url in
                try await authenticator.authenticate(url: url, callbackScheme: AppDependencies.oauthCallbackScheme, isPrivate: false)
            }
            guard renewed.id == credential.id else {
                throw DifferentAccountLoggedIn(expected: credential.handle, actual: renewed.handle)
            }
            // ログインし直している間に、別のシーンでログアウトや切り替えをしていたら、結果を捨てる。
            // 加えると、消したアカウントが戻ったり、切り替えたアカウントから戻ったりするため。
            if isCurrent {
                guard accounts.current?.id == credential.id else {
                    logger.info("reauthentication discarded: account changed")
                    return
                }
                try accounts.add(renewed)
            } else {
                guard try accounts.renew(renewed) else {
                    logger.info("reauthentication discarded: account removed")
                    return
                }
            }
            logger.info("account reauthenticated (current: \(isCurrent, privacy: .public))")
            Self.syncAllScenes()
        } catch is CancellationError {
            logger.info("reauthentication cancelled")
        } catch where Task.isCancelled {
            // 別のウィンドウでの切り替えなどで、ログインし直していたセッションを止めた。通信はURLErrorの取り消しで戻るので、失敗として知らせない。
            logger.info("reauthentication cancelled with session")
        } catch {
            logger.error("reauthentication failed: \(SciaLog.describe(error), privacy: .public)")
            window.rootViewController?.presentOnFrontmost(UIAlertController.failure(title: AccountSwitchTexts.reauthenticationFailure, reason: ErrorPresentation(error)))
        }
    }

    /// ログイン画面をシートで出し、ログインできたらそのアカウントに切り替える。
    /// キャンセルした後にログインの続きが終わっても、アカウントは加えない。閉じたのに別のアカウントへ切り替わらないようにするため。
    private func presentAddAccount() {
        guard let root = window?.rootViewController else { return }
        weak var sheet: UIViewController?
        let attempt = AddAccountAttempt()
        let model = LoginModel(oauth: AppDependencies.oauth, accountDomains: accountDomains) { [weak self] credential in
            guard !attempt.isCancelled else { return }
            try self?.accounts?.add(credential)
            Self.leaveDummySession()
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
        root.presentOnFrontmost(hosting)
    }

    /// ダミーを選んでいる間は、ログアウトさせない。ログアウトすると、ダミーではなく、裏で選んだままの本物のアカウントが消えるため。
    private static var canLogOut: Bool {
        #if DEBUG
        !showsDummySession
        #else
        true
        #endif
    }

    private func confirmLogOut() {
        guard let current = accounts?.current else { return }
        confirmLogOut(current)
    }

    private func confirmLogOut(_ account: Credential) {
        guard let root = window?.rootViewController else { return }
        let discardsDraft = Self.discardsDraft(loggingOut: account.id)
        let alert = UIAlertController(
            title: AccountSwitchTexts.LoggingOut.title(handle: account.handle),
            message: AccountSwitchTexts.LoggingOut.message(discardsDraft: discardsDraft),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: AccountSwitchTexts.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: AccountSwitchTexts.LoggingOut.confirm, style: .destructive) { [weak self] _ in
            self?.logOut(account)
        })
        root.presentOnFrontmost(alert)
    }

    /// アカウントの情報を端末から消す。ほかにアカウントがあればそちらに切り替え、なければログイン画面に戻る。
    /// サーバー側のトークンは失効させない。使う人がログアウトを選んだときだけ呼ぶ。APIの応答を理由には呼ばない。
    private func logOut(_ credential: Credential) {
        guard let accounts else {
            showCurrentAccount()
            return
        }
        do {
            try AccountLogout.logOut(credential, from: accounts, defaults: .standard, settings: AppDependencies.settings, images: AppDependencies.images)
        } catch {
            // 消せなければ、アカウントはアカウントのリストにも端末にも残っているので、今の画面のまま知らせる。
            // ログイン画面に替えると、残っているほかのアカウントにも、起動し直すまで戻れなくなるため。
            logger.error("account removal failed: \(SciaLog.describe(error), privacy: .public)")
            window?.rootViewController?.presentOnFrontmost(UIAlertController.failure(title: AccountSwitchTexts.logOutFailure, reason: ErrorPresentation(error)))
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
        // ログイン画面に替えたら、出していたアカウントの処理を止める。
        session = nil
        // ログアウトしたアカウントの投稿の編集や書き直しは、ほかのアカウントでは続けられないので捨てる（docs/compose.mdの「アカウントを変えるとき」）。
        // 開けるアカウントがなく、新しい画面一式へのつなぎ直しを通らないため、ここで捨てる。同じアカウントにログインし直しても戻さない。
        if let draft, let accounts, draft.pointsToServerPost, !accounts.accounts.contains(where: { $0.id == draft.writingAccountID }) {
            draft.reset()
        }
        windowSettings?.use(AppDependencies.settings)
        isShowingAccountsLoadFailure = false
        let model = LoginModel(oauth: AppDependencies.oauth, accountDomains: accountDomains) { [weak self] credential in
            guard let accounts = self?.accounts else {
                throw AccountsUnavailable()
            }
            try accounts.add(credential)
            Self.leaveDummySession()
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
        AccountSwitchTexts.differentAccountLoggedIn(expected: expected, actual: actual)
    }
}

/// 起動時にKeychainを読めず、アカウントを保存できない。
private struct AccountsUnavailable: LocalizedError {
    var errorDescription: String? {
        AccountSwitchTexts.accountsUnavailable
    }
}

extension SceneDelegate: AccountReauthenticating {
    /// 失敗の理由の「ログインし直す」から、そのアカウントにログインし直す。今のアカウントかほかのアカウントかは、セッションが分ける。
    func reauthenticate(_ account: RequestAccount) {
        session?.reauthenticate(account)
    }
}
