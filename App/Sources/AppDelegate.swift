import SciaCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        #if DEBUG
        // シーンのウィンドウができる前に差し替える
        MacNativeScale.installIfOnMac()
        #endif
        MacNavigationBarBackground.install()
        // 受け取られないまま残った共有拡張のファイルを消す。開かれたばかりの共有は新しいので消さない。
        SharedMediaInbox.app?.removeStale(now: AppDependencies.now())
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if MediaWindow.isViewerActivity(options.userActivities.first) {
            return UISceneConfiguration(name: MediaWindow.configurationName, sessionRole: connectingSceneSession.role)
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
