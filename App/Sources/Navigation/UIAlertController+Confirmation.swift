import SciaCore
import UIKit

extension UIAlertController {
    /// SciaCoreの確認を、アラートかアクションシートに描く。押されたボタンが選んだものを`onChoice`に渡す。キャンセルでは呼ばない。
    /// `onClose`は、キャンセルを含めてどのボタンで閉じても、`onChoice`より先に呼ぶ。
    convenience init<Choice>(_ confirmation: Confirmation<Choice>, preferredStyle: Style, onClose: @escaping () -> Void = {}, onChoice: @escaping (Choice) -> Void) {
        self.init(title: confirmation.title, message: confirmation.message, preferredStyle: preferredStyle)
        for button in confirmation.buttons {
            let style: UIAlertAction.Style = switch button.role {
            case .cancel: .cancel
            case .destructive: .destructive
            case .default: .default
            }
            addAction(UIAlertAction(title: button.title, style: style) { _ in
                onClose()
                if let choice = button.choice {
                    onChoice(choice)
                }
            })
        }
    }
}
