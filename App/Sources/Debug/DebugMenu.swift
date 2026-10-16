#if DEBUG
import SciaCore
import UIKit

extension UIViewController {
    /// Debugビルドだけで出す、開発用の機能をまとめたメニューボタン。
    /// - Parameter screenActions: 画面ごとの検証用の操作。共通の項目の前に区切って並べる。
    func makeDebugMenuButton(screenActions: [UIMenuElement] = []) -> UIBarButtonItem {
        let common: [UIMenuElement] = [
            // メニューの見出しはタップできないため、ビルド情報はコピーする項目として出す。
            // 1行にまとめると長いブランチ名でcommitが切れるため、commitは2行目に分ける
            UIAction(
                title: BuildInfo.current.branch,
                subtitle: "\(BuildInfo.current.version) @ \(BuildInfo.current.commit)",
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = BuildInfo.current.text
            },
            UIAction(title: "チューニング", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.presentTuningPanel()
            },
            UIAction(title: "部品カタログ", image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                self?.presentComponentCatalog()
            },
            // シミュレーターやUIテストからも開けるよう、シェイクと同じ処理をメニューにも置く。
            UIAction(title: "違和感レポート", image: UIImage(systemName: "exclamationmark.bubble")) { [weak self] _ in
                guard let window = self?.view.window else { return }
                DiscomfortReportPresenter.present(in: window)
            },
        ]
        let menu = UIMenu(children: [UIMenu(options: .displayInline, children: screenActions)] + common)
        let item = UIBarButtonItem(image: UIImage(systemName: "ladybug"), menu: menu)
        item.accessibilityLabel = "デバッグメニュー"
        return item
    }
}
#endif
