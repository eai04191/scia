import SciaCore
import UIKit

extension UIAlertController {
    /// SciaCoreの確認を、アラートかアクションシートに描く。押されたボタンが選んだものを`onChoice`に渡す。キャンセルでは呼ばない。
    convenience init<Choice>(_ confirmation: Confirmation<Choice>, preferredStyle: Style, onChoice: @escaping (Choice) -> Void) {
        self.init(title: confirmation.title, message: confirmation.message, preferredStyle: preferredStyle)
        for button in confirmation.buttons {
            let style: UIAlertAction.Style = switch button.role {
            case .cancel: .cancel
            case .destructive: .destructive
            case .default: .default
            }
            addAction(UIAlertAction(title: button.title, style: style) { _ in
                if let choice = button.choice {
                    onChoice(choice)
                }
            })
        }
    }
}
