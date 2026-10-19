#if DEBUG
import SciaCore
import UIKit

extension UIViewController {
    /// Debugビルドだけで出す、開発用の機能をまとめたメニューボタン。
    /// - Parameter screenActions: 画面ごとの検証用の操作。共通の項目の前に区切って並べる。
    /// - Parameter faults: 障害を起こす項目。セッションの読み込み直しにつながる画面でだけ渡す。
    /// - Parameter handle: `scia-debug://`と同じ操作をセッションに頼む。渡した画面でだけ、処理中のチップを出す項目を並べる。
    func makeDebugMenuButton(screenActions: [UIMenuElement] = [], faults: UIMenu? = nil, handle: (@MainActor (DebugURL) -> Void)? = nil) -> UIBarButtonItem {
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
        ] + (handle.map { handle in
            // チップの列の動き（画面を移る途中、引っぱる途中）を、実機でもダウンロードを用意せずに確かめるため。
            [UIAction(title: "処理中のチップを1分出す", image: UIImage(systemName: "hourglass")) { _ in
                handle(.progressNotice(seconds: 60))
            }]
        } ?? []) + [
            // シミュレーターやUIテストからも開けるよう、シェイクと同じ処理をメニューにも置く。
            UIAction(title: "違和感レポート", image: UIImage(systemName: "exclamationmark.bubble")) { [weak self] _ in
                guard let window = self?.view.window else { return }
                DiscomfortReportPresenter.present(in: window)
            },
        ] + (faults.map { [$0] } ?? [])
        let menu = UIMenu(children: [UIMenu(options: .displayInline, children: screenActions)] + common)
        let item = UIBarButtonItem(image: UIImage(systemName: "ladybug"), menu: menu)
        item.accessibilityLabel = "デバッグメニュー"
        return item
    }
}
#endif
