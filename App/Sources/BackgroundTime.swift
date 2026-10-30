import UIKit

/// 送っている途中にバックグラウンドへ移っても、送り終えるまでアプリを止めないよう頼む。
@MainActor
enum BackgroundTime {
    /// 頼んで、終えるときに呼ぶものを返す。与えられた時間が尽きたら、送り終えていなくても終える。尽きたあとはOSがアプリを止め、送っている途中の通信は失敗として戻る。
    static func request(_ name: String) -> @MainActor () -> Void {
        request(name) {}
    }

    /// `request(_:)`と同じく頼み、与えられた時間が尽きたら、終えてから`onExpire`を呼ぶ。尽きたことを知って、次に頼み直すのに使う。
    static func request(_ name: String, onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let request = Request()
        request.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                request.end()
                onExpire()
            }
        }
        return { request.end() }
    }

    @MainActor
    private final class Request {
        var identifier = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
