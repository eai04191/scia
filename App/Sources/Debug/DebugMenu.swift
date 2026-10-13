#if DEBUG
import UIKit

extension UIViewController {
    /// Debugビルドだけで出す、開発用の機能をまとめたメニューボタン。
    func makeDebugMenuButton() -> UIBarButtonItem {
        let menu = UIMenu(children: [
            UIAction(title: "チューニング", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.presentTuningPanel()
            },
        ])
        let item = UIBarButtonItem(image: UIImage(systemName: "ladybug"), menu: menu)
        item.accessibilityLabel = "デバッグメニュー"
        return item
    }
}
#endif
