import os
import SciaCore
import UIKit

/// Macでは、添付ファイルのビューアを別のウィンドウで開く。タイムラインのウィンドウを縦長に置いていると、同じウィンドウの中では画像がほとんど大きくならないため。
/// 開く添付ファイルは同じプロセスの中で受け渡す。シーンにはIDだけを渡し、新しいウィンドウがIDで受け取る。
@MainActor
enum MediaWindow {
    static let activityType = "net.mizle.scia.media-viewer"
    static let configurationName = "Media Viewer"
    private static let requestIDKey = "requestID"
    /// Macのウィンドウのタイトル。AeroSpaceなどがタイムラインのウィンドウと見分けるために使う。
    static let windowTitle = "Scia メディア"

    struct Request {
        let attachments: [MediaAttachment]
        let startIndex: Int
        let store: MediaImageStore
        let dragToDismiss: DragToDismiss
        let timing: MediaViewerController.Timing
        let transfers: MediaTransferCenter?
        /// アプリ全体のアプリ内通知。ビューアのウィンドウにもチップの列を重ね、全部のウィンドウに出す。
        let notices: NoticeCenter?
        let subject: OperationStatus.Subject?
    }

    private static var pending: [UUID: Request] = [:]

    static var isAvailable: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    static func open(_ request: Request, from requestingScene: UIScene?) {
        let id = UUID()
        pending[id] = request
        let activity = NSUserActivity(activityType: activityType)
        activity.userInfo = [requestIDKey: id.uuidString]
        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = requestingScene
        UIApplication.shared.activateSceneSession(
            for: UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity, options: options)
        ) { error in
            pending[id] = nil
            SciaLog.logger(category: "media").error("viewer window failed: \(SciaLog.describe(error), privacy: .public)")
        }
    }

    static func isViewerActivity(_ activity: NSUserActivity?) -> Bool {
        activity?.activityType == activityType
    }

    /// 預けた添付ファイルを受け取る。受け取れるのは一度だけ。
    static func takeRequest(from activity: NSUserActivity?) -> Request? {
        guard let value = activity?.userInfo?[requestIDKey] as? String, let id = UUID(uuidString: value) else { return nil }
        return pending.removeValue(forKey: id)
    }
}

/// ビューアのウィンドウ。ビューアが閉じたら、ウィンドウも閉じる。
final class MediaWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // 他のアプリから開かれたURL（`scia://profile/...`など）は受け取らず、タイムラインのウィンドウに届ける。
        // 既定ではどのシーンも受け取れるため、ビューアが手前にあるとビューアに届き、処理されずに捨てられる。
        windowScene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(value: false)
        // アプリを起動し直したときにシステムが復元したウィンドウには、受け取る添付ファイルがないため閉じる。
        guard let request = MediaWindow.takeRequest(from: connectionOptions.userActivities.first) else {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MediaWindowRootController(request: request) {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
        self.window = window
        window.makeKeyAndVisible()
        if let notices = request.notices {
            NoticeOverlay.install(in: window, center: notices)
        }
        #if DEBUG
        MacWindowTitle.set(MediaWindow.windowTitle, for: window)
        #endif
    }
}

/// ビューアのウィンドウの土台。画面に載ってからビューアを出す。
private final class MediaWindowRootController: UIViewController {
    private var request: MediaWindow.Request?
    private let onClose: @MainActor () -> Void

    init(request: MediaWindow.Request, onClose: @escaping @MainActor () -> Void) {
        self.request = request
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let request else { return }
        self.request = nil
        MediaViewerController.present(
            attachments: request.attachments,
            startIndex: request.startIndex,
            store: request.store,
            dragToDismiss: request.dragToDismiss,
            timing: request.timing,
            from: self,
            transfers: request.transfers,
            subject: request.subject,
            // 戻る先のサムネイルがないので、画像を動かさずに薄くして開閉する。
            sourceTile: { _ in nil },
            onDismiss: onClose
        )
    }
}
