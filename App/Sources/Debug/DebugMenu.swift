#if DEBUG
import SciaCore
import UIKit

extension UIViewController {
    /// Debugビルドだけで出す、開発用の機能をまとめたメニューボタン。
    func makeDebugMenuButton() -> UIBarButtonItem {
        let menu = UIMenu(children: [
            UIAction(title: "チューニング", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.presentTuningPanel()
            },
            // シミュレーターやUIテストからも開けるよう、シェイクと同じ処理をメニューにも置く。
            UIAction(title: "違和感レポート", image: UIImage(systemName: "exclamationmark.bubble")) { [weak self] _ in
                guard let window = self?.view.window else { return }
                DiscomfortReportPresenter.present(in: window)
            },
            // ログインの確認をやり直すためのもの。サーバー側のトークンは失効させず、端末の認証情報だけを消す。
            UIAction(title: "ログアウト", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) { [weak self] _ in
                guard let sceneDelegate = self?.view.window?.windowScene?.delegate as? SceneDelegate else { return }
                do {
                    try AppDependencies.credentials.delete()
                    sceneDelegate.showLogin(errorMessage: nil)
                } catch {
                    sceneDelegate.showLogin(errorMessage: error.localizedDescription)
                }
            },
        ])
        let item = UIBarButtonItem(image: UIImage(systemName: "ladybug"), menu: menu)
        item.accessibilityLabel = "デバッグメニュー"
        return item
    }
}
#endif
