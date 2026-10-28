import SciaCore
import UIKit
import os

/// 短い間に異常な数のリクエストを送ったら、内訳と、そのとき表示していた画面をerrorのログに残す。
/// errorはOSがディスクに残し、続いている間も10秒に1行しか出さないので、OSにログを止められる前に記録できる。
@MainActor
enum RequestBurstLog {
    private static let logger = SciaLog.logger(category: "network")

    /// アプリのすべての通信の口で共有する。
    nonisolated static let monitor = RequestBurstMonitor { burst in
        Task { @MainActor in
            logger.error("request burst \(burst.summary, privacy: .public) topURL=\(burst.topURL.name, privacy: .private(mask: .hash)) screens=\(screens(), privacy: .public)")
        }
    }

    /// 表示中のウィンドウごとの、根から一番手前の画面までの型の名前。
    private static func screens() -> String {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState != .background }
            .flatMap { $0.windows }
            .filter { !$0.isHidden }
        return windows.compactMap { $0.rootViewController.map(path(from:)) }.joined(separator: " | ")
    }

    private static func path(from root: UIViewController) -> String {
        var names: [String] = []
        var current: UIViewController? = root
        while let controller = current {
            names.append(String(describing: type(of: controller)))
            current = controller.presentedViewController ?? NoticeOverlay.frontChild(of: controller)
        }
        return names.joined(separator: ">")
    }
}
