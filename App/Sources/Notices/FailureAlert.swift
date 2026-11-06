import SciaCore
import SwiftUI
import UIKit

extension UIAlertController {
    /// 失敗の理由を出すアラート。理由にログアウトされたアカウントがあれば、そのアカウントでログインし直すボタンを添える。
    /// 理由を見せるところがこれを使えば、どの操作の失敗からでも、その場でログインし直せる。
    /// - Parameters:
    ///   - logIn: ログインし直すボタンが押されたときに、そのアカウントを渡して呼ぶ。
    ///   - onClose: どちらのボタンでも、閉じたときに呼ぶ。
    static func failure(title: String, reason: ErrorPresentation, logIn: @escaping @MainActor (RequestAccount) -> Void, onClose: (@MainActor () -> Void)? = nil) -> UIAlertController {
        let alert = UIAlertController(title: title, message: reason.text, preferredStyle: .alert)
        if let account = reason.loggedOutAccount {
            alert.addAction(UIAlertAction(title: "ログインし直す", style: .default) { _ in
                onClose?()
                logIn(account)
            })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in onClose?() })
        return alert
    }
}

/// 画面の中に出す失敗の理由。理由にログアウトされたアカウントがあれば、`UIAlertController.failure`と同じく、そのアカウントでログインし直すボタンを添える。
struct FailureReasonView: View {
    let reason: ErrorPresentation
    let logIn: @MainActor (RequestAccount) -> Void

    var body: some View {
        Text(reason.message)
        if let account = reason.loggedOutAccount {
            // 理由の文字に付けた色（失敗の赤など）を引き継がず、押せる行としてアクセントカラーで出す。
            Button("ログインし直す") { logIn(account) }
                .foregroundStyle(.tint)
        }
    }
}
