#if DEBUG
import SciaCore
import UIKit

extension UIViewController {
    /// Debugビルドだけで出す、開発用の機能をまとめたメニューボタン。
    /// ビルド情報、開発の道具、画面ごとの検証用の操作、アプリ全体で起こす操作の順に、区切って並べる。
    /// - Parameter screenActions: 画面ごとの検証用の操作。「この画面」の見出しの下に並べる。
    /// - Parameter faults: 障害を起こす項目。セッションの読み込み直しにつながる画面でだけ渡す。
    /// - Parameter handle: `scia-debug://`と同じ操作をセッションに頼む。渡した画面でだけ、処理中のチップを出す項目を並べる。
    func makeDebugMenuButton(screenActions: [UIMenuElement] = [], faults: UIMenu? = nil, handle: (@MainActor (DebugURL) -> Void)? = nil) -> UIBarButtonItem {
        // メニューの見出しはタップできないため、ビルド情報はコピーする項目として出す。
        // 1行にまとめると長いブランチ名でcommitが切れるため、commitは2行目に分ける
        let buildInfo = UIAction(
            title: BuildInfo.current.branch,
            subtitle: "\(BuildInfo.current.version) @ \(BuildInfo.current.commit)",
            image: UIImage(systemName: "doc.on.doc")
        ) { _ in
            UIPasteboard.general.string = BuildInfo.current.text
        }
        let tools: [UIMenuElement] = [
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
        let appWide: [UIMenuElement] = (handle.map { handle in
            [
                // チップの列の動き（画面を移る途中、引っぱる途中）を、実機でもダウンロードを用意せずに確かめるため。
                UIAction(title: "処理中のチップを1分出す", image: UIImage(systemName: "hourglass")) { _ in
                    handle(.progressNotice(seconds: 60, title: nil))
                },
                // 添付ファイルの列や送る前に縮める流れを、ピッカーで写真を選ばずに確かめるため。サーバーにアップロードする。
                UIMenu(title: "投稿欄に画像を添付", image: UIImage(systemName: "photo.on.rectangle"), children: (1...4).map { count in
                    UIAction(title: "\(count)枚") { _ in
                        handle(.compose(text: nil, mediaCount: count))
                    }
                }),
                // オンとオフのチェックマークを、開くたびに今の状態で出す。
                UIDeferredMenuElement.uncached { completion in
                    let isOn = DebugFaults.isHoldingArrivals
                    completion([
                        UIAction(
                            title: "新着を溜める",
                            subtitle: isOn ? "選び直すと、溜まった新着を挿入する" : "ホームと通知",
                            image: UIImage(systemName: "tray.full"),
                            state: isOn ? .on : .off
                        ) { _ in
                            handle(.holdArrivals(!isOn))
                        },
                    ])
                },
            ]
        } ?? []) + (faults.map { [$0] } ?? [])
        let sections: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [buildInfo]),
            UIMenu(title: "道具", options: .displayInline, children: tools),
            UIMenu(title: "この画面", options: .displayInline, children: screenActions),
            UIMenu(title: "アプリ全体", options: .displayInline, children: appWide),
        ]
        let item = UIBarButtonItem(image: UIImage(systemName: "ladybug"), menu: UIMenu(children: sections))
        item.accessibilityLabel = "デバッグメニュー"
        return item
    }
}
#endif
