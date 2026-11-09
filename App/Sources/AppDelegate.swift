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
        startPostCrashGuard()
        AppDependencies.stateDumps.register("emojiImages", owner: AppDependencies.emojiImages) { $0.stateDump() }
        // 受け取られないまま残った共有拡張のファイルを消す。開かれたばかりの共有は新しいので消さない。
        SharedMediaInbox.app?.removeStale(now: AppDependencies.now())
        return true
    }

    private func startPostCrashGuard() {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        AppDependencies.postCrashGuard.start(markFile: folder.appending(path: "crash-mark"))
    }

    /// メモリに持つ画像のうち、使っていないものをすべて手放す。描いている画像は残す（docs/image-loading.mdの「メモリに持つ画像」）。
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppDependencies.emojiImages.releaseUnusedMemory()
        AppDependencies.avatarImages.releaseUnusedMemory()
        AppDependencies.mediaImages.releaseUnusedMemory()
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
