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
        // 同じ投稿が両方のタブにあることがあるため、どちらにも反映する。
        interactions = StatusInteractions(operations: .init(client: client)) { id, transform in
            home.updateStatus(id, transform)
            notifications.updateStatus(id, transform)
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
        rootViewController = tabBarController
        forward = { [weak self] message in
            guard let self else { return }
            onUnauthorized(self, message)
        }
        for viewController in [home.viewController, notifications.viewController] {
            viewController.navigationItem.leftBarButtonItem = Self.accountButton(for: credential, menu: accountMenu)
            viewController.myAccountID = credential.accountID
            viewController.onStatusAction = { [weak self] action, status in self?.perform(action, on: status) }
        }
        home.viewController.onCompose = { [weak self] in self?.presentCompose(replyingTo: nil) }
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
            presentCompose(replyingTo: status)
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

    private func presentCompose(replyingTo status: Status?) {
        let client = client
        let model = ComposeModel(replyTo: status, myAccountID: client.credential.accountID) { draft in
            _ = try await client.postStatus(draft)
        }
        let hosting = ComposeHostingController(model: model)
        model.onFinish = { [weak hosting] in hosting?.dismiss(animated: true) }
        rootViewController.present(hosting, animated: true)
        Task { [weak self] in
            guard let self else { return }
            let defaults = await self.loadComposeDefaults()
            model.apply(configuration: defaults.configuration, defaultVisibility: defaults.visibility)
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

/// 投稿画面を出す。書きかけのときは下へのスワイプで閉じず、破棄してよいか確かめる。
@MainActor
private final class ComposeHostingController: UIHostingController<ComposeView>, UIAdaptivePresentationControllerDelegate {
    private let model: ComposeModel

    init(model: ComposeModel) {
        self.model = model
        super.init(rootView: ComposeView(model: model))
        presentationController?.delegate = self
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !model.isDirty && !model.isPosting
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        model.cancel()
    }
}
