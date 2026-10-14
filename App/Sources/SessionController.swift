import os
import SciaCore
import SwiftUI
import UIKit

/// ログイン中のアカウントの画面一式。タブの組み立てと、各タブの読み込みと接続の寿命をまとめる。
@MainActor
final class SessionController {
    let rootViewController: UIViewController
    /// このセッションで使っているアカウント。
    let credential: Credential
    private let home: HomeTimelineController
    private let notifications: NotificationsController
    private let client: MastodonClient
    private let interactions: StatusInteractions
    private let report: (String) -> Void
    private let tabBarDelegate: TabReselectionDelegate
    /// 開いているプロフィール画面。投稿への操作の結果を反映するために持つ。閉じたものは自然に消える。
    private let profiles: ProfileRegistry
    private var cachedMyAccount: Account?
    /// タブバーの上の投稿欄。ホームと通知のどちらでも同じ下書きを使う。
    private let composer: InlineComposeController
    /// 投稿欄が覆っている高さを伝える一覧。ホームと通知に加え、開いているプロフィールの一覧も入る。閉じたものは自然に消える。
    private let timelines = NSHashTable<TimelineViewController>.weakObjects()
    private var composerObscuredHeight: CGFloat = 0
    /// 投稿画面で使う、インスタンスの上限とユーザーの既定の公開範囲。一度読めたら使い回す。
    private var composeDefaults: (configuration: InstanceConfiguration?, visibility: Status.Visibility?)?
    private let logger = SciaLog.logger(category: "session")

    /// - Parameters:
    ///   - accountMenu: アカウントの切り替えなどのメニュー。開くたびに呼んで組み立て直す。
    ///   - onUnauthorized: トークンが無効だったとき、どのセッションからの通知かを添えて呼ぶ。
    init(credential: Credential, accountMenu: @escaping @MainActor () -> UIMenu, onUnauthorized: @escaping (SessionController, String) -> Void) {
        self.credential = credential
        let client = MastodonClient(credential: credential, transport: URLSessionTransport())
        let streaming = StreamingClient(credential: credential, connector: URLSessionWebSocketConnector())
        var forward: (String) -> Void = { _ in }
        let home = HomeTimelineController(client: client, streaming: streaming) { _, message in forward(message) }
        let notifications = NotificationsController(client: client, streaming: streaming) { _, message in forward(message) }
        self.home = home
        self.notifications = notifications
        self.client = client
        let profiles = ProfileRegistry()
        self.profiles = profiles
        // 同じ投稿が両方のタブと開いているプロフィールにあることがあるため、どれにも反映する。
        interactions = StatusInteractions(operations: .init(client: client)) { id, transform in
            home.updateStatus(id, transform)
            notifications.updateStatus(id, transform)
            profiles.updateStatus(id, transform)
        }
        report = { message in forward(message) }

        let homeNavigation = UINavigationController(rootViewController: home.viewController)
        let notificationsNavigation = UINavigationController(rootViewController: notifications.viewController)
        let notificationsTab = UITab(title: "通知", image: UIImage(systemName: "bell"), identifier: "notifications") { _ in notificationsNavigation }
        notifications.onUnreadCountChange = { count, isLowerBound in
            notificationsTab.badgeValue = count == 0 ? nil : isLowerBound ? "\(count)+" : "\(count)"
        }
        let tabBarController = UITabBarController(tabs: [
            UITab(title: "ホーム", image: UIImage(systemName: "house"), identifier: "home") { _ in homeNavigation },
            notificationsTab,
        ])
        tabBarDelegate = TabReselectionDelegate { navigation in
            (navigation.viewControllers.first as? TimelineViewController)?.scrollToNewest()
        }
        tabBarController.delegate = tabBarDelegate
        composer = InlineComposeController(model: ComposeModel(myAccountID: credential.accountID) { draft in
            _ = try await client.postStatus(draft)
        })
        tabBarController.bottomAccessory = composer.accessory
        rootViewController = tabBarController
        forward = { [weak self] message in
            guard let self else { return }
            onUnauthorized(self, message)
        }
        for viewController in [home.viewController, notifications.viewController] {
            viewController.navigationItem.leftBarButtonItem = Self.accountButton(for: credential) { [weak self, weak viewController] in
                let myProfile = UIAction(title: "自分のプロフィール", image: UIImage(systemName: "person.crop.circle")) { _ in
                    guard let viewController else { return }
                    self?.openMyProfile(from: viewController)
                }
                return UIMenu(children: [UIMenu(options: .displayInline, children: [myProfile])] + accountMenu().children)
            }
            configure(viewController)
        }
        home.viewController.onCompose = { [weak self] in self?.expandCompose() }
        composer.onBeginEditing = { [weak self] in self?.applyComposeDefaults() }
        composer.onExpand = { [weak self] in self?.expandCompose() }
        composer.onObscuredHeightChange = { [weak self] height in
            guard let self else { return }
            composerObscuredHeight = height
            for timeline in timelines.allObjects {
                timeline.setObscuredBottomHeight(height)
            }
        }
        composer.onPosted = { [weak self] in
            guard let self, self.rootViewController.presentedViewController is ComposeHostingController else { return }
            self.rootViewController.dismiss(animated: true)
        }
        // 投稿欄を置くとタブバーの画面を読み込むため、各一覧の設定（投稿ボタンを付けるonComposeなど）を終えてから置く。
        composer.install(in: tabBarController)
    }

    /// 一覧から投稿への操作とプロフィールを開けるようにする。プロフィール画面の一覧にも使う。
    private func configure(_ viewController: TimelineViewController) {
        timelines.add(viewController)
        viewController.setObscuredBottomHeight(composerObscuredHeight)
        viewController.myAccountID = credential.accountID
        viewController.onStatusAction = { [weak self] action, status in self?.perform(action, on: status) }
        viewController.onOpenProfile = { [weak self, weak viewController] account in
            guard let viewController else { return }
            self?.openProfile(account, from: viewController)
        }
    }

    // MARK: - プロフィール

    private func openProfile(_ account: Account, from source: UIViewController) {
        let (controller, viewController) = ProfileController.make(account: account, client: client) { [weak self] error, title in
            self?.handle(error, title: title)
        }
        configure(viewController)
        profiles.add(controller)
        source.navigationController?.pushViewController(viewController, animated: true)
        controller.start()
    }

    /// ログイン中のアカウント。手元にはCredentialしかないため、一度読んだら使い回す。
    func myAccount() async throws -> Account {
        if let cachedMyAccount { return cachedMyAccount }
        let account = try await client.account(client.credential.accountID)
        cachedMyAccount = account
        return account
    }

    private func openMyProfile(from source: UIViewController) {
        Task {
            do {
                let account = try await myAccount()
                openProfile(account, from: source)
            } catch {
                logger.error("my profile load failed: \(error.localizedDescription, privacy: .public)")
                handle(error, title: "プロフィールを読み込めませんでした")
            }
        }
    }

    /// 使っているアカウントを示し、押すとアカウントのメニューを開く。
    private static func accountButton(for credential: Credential, menu: @escaping @MainActor () -> UIMenu) -> UIBarButtonItem {
        let deferred = UIDeferredMenuElement.uncached { completion in
            completion(menu().children)
        }
        let item = UIBarButtonItem(image: UIImage(systemName: "person.crop.circle"), menu: UIMenu(children: [deferred]))
        item.accessibilityLabel = "アカウント"
        item.accessibilityValue = credential.handle
        return item
    }

    // MARK: - 投稿への操作

    private func perform(_ action: StatusAction, on status: Status) {
        switch action {
        case .reply:
            composer.reply(to: status)
        case .favourite:
            toggle(.favourite, on: status, failureTitle: "お気に入りを変更できませんでした")
        case .reblog:
            toggle(.reblog, on: status, failureTitle: "ブーストを変更できませんでした")
        }
    }

    private func toggle(_ action: StatusInteractions.Action, on status: Status, failureTitle: String) {
        Task {
            do {
                try await interactions.toggle(action, on: status)
            } catch {
                logger.error("toggle \(String(describing: action), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                handle(error, title: failureTitle)
            }
        }
    }

    private func handle(_ error: any Error, title: String) {
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            report("ログインの有効期限が切れたか、アプリの許可が取り消されました。ログインし直してください。")
            return
        }
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        topViewController.present(alert, animated: true)
    }

    /// いちばん手前に出ている画面。投稿画面を出している間の失敗も、その上に出す。
    private var topViewController: UIViewController {
        var top = rootViewController
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - 投稿

    /// 投稿欄の下書きのまま、全画面の投稿画面を出す。
    private func expandCompose() {
        applyComposeDefaults()
        rootViewController.present(ComposeHostingController(model: composer.model), animated: true)
    }

    /// 既定の公開範囲などを読めたら、投稿欄に反映する。読めなかったら、次に書き始めたときに読み直す。
    private func applyComposeDefaults() {
        Task { [weak self] in
            guard let self else { return }
            let defaults = await self.loadComposeDefaults()
            self.composer.model.apply(configuration: defaults.configuration, defaultVisibility: defaults.visibility)
        }
    }

    /// 読めなかった値は既定のまま投稿画面を使えるようnilにし、次に開いたときに読み直す。
    private func loadComposeDefaults() async -> (configuration: InstanceConfiguration?, visibility: Status.Visibility?) {
        if let composeDefaults { return composeDefaults }
        async let configuration = try? client.instanceConfiguration()
        async let visibility = try? client.defaultVisibility()
        let defaults = (await configuration, await visibility)
        if defaults.0 != nil, defaults.1 != nil {
            composeDefaults = defaults
        }
        return defaults
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

    /// 他のアプリから開かれたURLの画面を出す。
    func open(_ url: AppURL) {
        switch url {
        case .profile(let acct):
            openProfile(acct: acct)
        }
    }

    /// acctでアカウントを探して、ホームのタブにプロフィールを開く。ホームを選んでいなければホームに切り替える。
    private func openProfile(acct: String) {
        let client = client
        Task {
            do {
                guard let account = try await client.resolveAccount(acct) else {
                    logger.error("profile not found acct=\(acct, privacy: .public)")
                    handle(ProfileNotFound(acct: acct), title: "プロフィールを開けませんでした")
                    return
                }
                (rootViewController as? UITabBarController)?.selectedIndex = 0
                openProfile(account, from: home.viewController)
            } catch {
                handle(error, title: "プロフィールを開けませんでした")
            }
        }
    }

    #if DEBUG
    func handle(_ url: DebugURL) {
        switch url {
        case .dummy(let post):
            home.streamDummy(post)
        }
    }
    #endif

    func enterForeground() {
        home.enterForeground()
        notifications.enterForeground()
    }

    func enterBackground() {
        home.enterBackground()
        notifications.enterBackground()
    }
}

private struct ProfileNotFound: LocalizedError {
    let acct: String

    var errorDescription: String? { "@\(acct)が見つかりませんでした。" }
}

/// 開いているプロフィール画面を弱く持つ。
@MainActor
private final class ProfileRegistry {
    private struct Entry {
        weak var controller: ProfileController?
    }

    private var entries: [Entry] = []

    func add(_ controller: ProfileController) {
        entries.removeAll { $0.controller == nil }
        entries.append(Entry(controller: controller))
    }

    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        entries.removeAll { $0.controller == nil }
        for entry in entries {
            entry.controller?.updateStatus(id, transform)
        }
    }
}

/// 選んでいるタブをもう一度押したとき、奥の画面を開いていれば標準どおり最初の画面へ戻し、最初の画面にいれば最上部へ動かす。
@MainActor
private final class TabReselectionDelegate: NSObject, UITabBarControllerDelegate {
    private let scrollToTop: (UINavigationController) -> Void

    init(scrollToTop: @escaping (UINavigationController) -> Void) {
        self.scrollToTop = scrollToTop
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab == tabBarController.selectedTab,
              let navigation = tab.viewController as? UINavigationController,
              navigation.viewControllers.count == 1
        else { return true }
        scrollToTop(navigation)
        return false
    }
}

/// 投稿欄を広げた画面を出す。閉じても下書きは投稿欄に残るため、下へのスワイプでも閉じられる。投稿中だけは閉じない。
@MainActor
private final class ComposeHostingController: UIHostingController<ComposeView>, UIAdaptivePresentationControllerDelegate {
    private let model: ComposeModel

    init(model: ComposeModel) {
        self.model = model
        super.init(rootView: ComposeView(model: model) {})
        // 閉じる操作は自分を参照するため、初期化を終えてから差し替える。
        rootView = ComposeView(model: model) { [weak self] in self?.dismiss(animated: true) }
        presentationController?.delegate = self
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !model.isPosting
    }
}
