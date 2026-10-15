#if DEBUG
import Foundation
import os
import SciaCore
import UIKit

/// MacでDesigned for iPadとして動かすとき、Macのウィンドウ（NSWindow）のタイトルを書き換える。
/// `UIWindowScene.title`はDesigned for iPadではMacのウィンドウに反映されず、どのウィンドウも「Scia」になるため、
/// AeroSpaceなどのウィンドウマネージャーがタイトルでウィンドウを見分けられない。
/// 同じプロセスで動いているAppKitのウィンドウを、UIWindowを持っているかで探す。非公開の`uiWindows`を使うのでDEBUGに限る。
@MainActor
enum MacWindowTitle {
    private static let logger = SciaLog.logger(category: "mac")

    /// UIWindowを表示した直後は、まだMacのウィンドウとつながっていない。つながるまで間を置いて試す。
    /// AeroSpaceはウィンドウを見つけた時点のタイトルで規則を当てるため、間はできるだけ短くする。
    static func set(_ title: String, for window: UIWindow) {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        Task { @MainActor [weak window] in
            for _ in 0..<60 {
                guard let window else { return }
                if let nsWindow = nsWindow(containing: window) {
                    nsWindow.setValue(title, forKey: "title")
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            logger.error("Macのウィンドウが見つからず、タイトルを書き換えられない")
        }
    }

    private static func nsWindow(containing window: UIWindow) -> NSObject? {
        let sharedApplication = NSSelectorFromString("sharedApplication")
        let windowsKey = NSSelectorFromString("windows")
        let uiWindowsKey = NSSelectorFromString("uiWindows")
        let setTitle = NSSelectorFromString("setTitle:")
        // 存在しないキーをKVCで読むと例外で落ちるため、読む前に応答するか確かめる。
        guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              applicationClass.responds(to: sharedApplication),
              let application = applicationClass.perform(sharedApplication)?.takeUnretainedValue() as? NSObject,
              application.responds(to: windowsKey),
              let nsWindows = application.value(forKey: "windows") as? [NSObject]
        else { return nil }
        return nsWindows.first { nsWindow in
            guard nsWindow.responds(to: uiWindowsKey), nsWindow.responds(to: setTitle),
                  let uiWindows = nsWindow.value(forKey: "uiWindows") as? [UIWindow]
            else { return false }
            return uiWindows.contains(window)
        }
    }
}
#endif
