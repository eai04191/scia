import SciaCore
import UIKit

/// ビューアのページの中央に出す、読み込み中と見せられないことの表示（`MediaStatusView`）。
/// 読み込めないのは、通信の失敗やサーバーのファイルの欠けで起き、実物で出すのに手間がかかるため並べる。ビューアと同じく、画像の上に置く。
/// サムネイルから映像への切り替わりと、表示の出入りは動きなので、遅いサーバーを使った実物で見る。
enum MediaStatusCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "読み込み中") { status(.loading) },
            CatalogState(title: "GIFを読み込めなかった") { status(.failed(PlayerPageController.failureText(of: .gifv))) },
            CatalogState(title: "動画を読み込めなかった") { status(.failed(PlayerPageController.failureText(of: .video))) },
            CatalogState(title: "画像を読み込めなかった") { status(.failed("画像を読み込めませんでした")) },
            CatalogState(title: "アプリで表示できない種類のファイル") { status(.failed("このファイルはアプリで表示できません")) },
            CatalogState(title: "投稿欄で選んだメディアを読み込めなかった（ブラウザで開くURLがない）") {
                status(.failed("画像を読み込めませんでした"), opens: false)
            },
            CatalogState(title: "読み込めなかった（文字を最大にしている）") {
                status(.failed(PlayerPageController.failureText(of: .video)), contentSize: .accessibilityExtraExtraExtraLarge)
            },
        ]
    }

    @MainActor
    private static func status(_ state: MediaStatusView.State, opens: Bool = true, contentSize: UIContentSizeCategory? = nil) -> UIView {
        let view = MediaStatusView()
        if opens {
            view.onOpen = {}
        }
        view.setState(state, animated: false)
        if let contentSize {
            view.traitOverrides.preferredContentSizeCategory = contentSize
        }
        return CatalogBackdrop.image(view) { backdrop, view in
            [
                view.topAnchor.constraint(equalTo: backdrop.topAnchor),
                view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                view.heightAnchor.constraint(equalToConstant: 240),
            ]
        }
    }
}
