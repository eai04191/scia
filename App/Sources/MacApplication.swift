import Foundation
import os
import SciaCore

/// Macで動くときの、プロセスにあるAppKitの`NSApplication`。
/// MacのDesigned for iPadでは、ほかのアプリが手前にあっても、シーンは`foregroundActive`、ウィンドウは`isKeyWindow`のままで、
/// `activateSceneSession`を呼んでも手前に出ない。iPadアプリのままでは、Sciaが手前のアプリかを知る方法も、手前に出す方法もないため、名前で呼ぶ。
/// 将来のmacOSで呼べなくなったら、手前かどうかは分からない扱いになり、手前に出す操作は何もしない。
@MainActor
enum MacApplication {
    /// Sciaが手前のアプリになった。AppKitが`NotificationCenter.default`に送る。
    static let didBecomeActiveNotification = Notification.Name("NSApplicationDidBecomeActiveNotification")
    /// Sciaが手前のアプリでなくなった。AppKitが`NotificationCenter.default`に送る。
    static let didResignActiveNotification = Notification.Name("NSApplicationDidResignActiveNotification")

    private static let logger = SciaLog.logger(category: "mac")
    private static var hasReportedUnavailable = false

    /// Sciaが手前のアプリか。Macでないとき、`NSApplication`を呼べないときはnil。
    static var isActive: Bool? {
        guard let application = application(respondingTo: ["isActive"]) else { return nil }
        return application.value(forKey: "active") as? Bool
    }

    /// 手前のアプリでなければ、手前に出す。
    static func activate() {
        guard let application = application(respondingTo: ["isActive", "activate"]) else { return }
        guard application.value(forKey: "active") as? Bool == false else { return }
        logger.info("activating app")
        application.perform(NSSelectorFromString("activate"))
    }

    /// Macでないとき、`NSApplication`がないとき、`selectors`のどれかに応答しないときはnil。
    private static func application(respondingTo selectors: [String]) -> NSObject? {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return nil }
        let sharedApplication = NSSelectorFromString("sharedApplication")
        // 応答しないメソッドを呼んだり、存在しないキーをKVCで読んだりすると例外で落ちるため、呼ぶ前に応答するか確かめる。
        guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              applicationClass.responds(to: sharedApplication),
              let application = applicationClass.perform(sharedApplication)?.takeUnretainedValue() as? NSObject,
              selectors.allSatisfy({ application.responds(to: NSSelectorFromString($0)) })
        else {
            // タイムラインは画面を出すたびに調べるため、呼べないことは1回だけ残す。
            if !hasReportedUnavailable {
                hasReportedUnavailable = true
                logger.error("NSApplication not available")
            }
            return nil
        }
        return application
    }
}
