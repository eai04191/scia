#if DEBUG
import CoreFoundation
import Foundation
import os
import SciaCore

/// シナリオ（UIテスト）から撮影モードのアプリへのシグナル。同じ端末の中のプロセス間の通知（Darwin通知）で受け取る。
///
/// URLで送ると、システムがアプリを一度切り替える扱いになり、ステータスバーに「◀ Scia」（元のアプリへ戻るボタン）が出て素材に写り、
/// 切り替えの間はメインスレッドで動かしている動き（ビューアの開閉など）が止まった。Darwin通知ではアプリが切り替わらない。
///
/// 通知の名前は`net.mizle.scia.scenario.<パス>`。パスはデバッグURLのホストから後ろ（`scenario/arrivals-top`、`viewer?index=0`など）。
/// Darwin通知は中身を運べず、名前を前もって登録する必要があるので、受け取るパスを並べて登録する。
@MainActor
enum ScenarioSignals {
    static let prefix = "net.mizle.scia.scenario."

    private static var handler: ((String) -> Void)?
    private static let logger = SciaLog.logger(category: "scenario")

    /// `paths`のシグナルを受け取り始める。受け取ったパスを`handler`に渡す。
    static func listen(for paths: [String], handler: @escaping (String) -> Void) {
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for path in paths {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                Task { @MainActor in ScenarioSignals.deliver(name) }
            }, (prefix + path) as CFString, nil, .deliverImmediately)
        }
        logger.info("scenario signals listening \(paths.count, privacy: .public)")
    }

    private static func deliver(_ name: String) {
        let path = String(name.dropFirst(prefix.count))
        logger.info("scenario signal \(path, privacy: .public)")
        handler?(path)
    }
}
#endif
