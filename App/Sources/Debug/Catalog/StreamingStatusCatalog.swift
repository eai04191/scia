#if DEBUG
import SciaCore
import UIKit

/// 一覧を最上部からさらに引っぱったときに見せる、ストリーミングの状態（`StreamingStatusPullView`）。
/// 本物は引っぱった分だけ薄く出るため、カタログでは濃さを変えずに置く。
enum StreamingStatusCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "接続中") { status(.connected) },
            CatalogState(title: "接続待ち") { status(.connecting) },
            CatalogState(title: "切断中・ポーリング中") { status(.polling) },
            CatalogState(title: "停止中（ログインが必要）") { status(.loginRequired) },
            CatalogState(title: "停止中（バックグラウンドなど。画面には出ない）") { status(.stopped) },
            CatalogState(title: "未接続") { status(nil) },
            CatalogState(title: "いちばん長い文言（狭い幅で折り返す）") { status(.loginRequired, width: 220) },
        ]
    }

    @MainActor
    private static func status(_ state: ConnectionDiagnostics.StreamingState?, width: CGFloat? = nil) -> UIView {
        let view = StreamingStatusPullView()
        view.setState(state)
        let framed = CatalogFrame.bordered(view)
        guard let width else { return framed }
        let container = UIView()
        framed.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(framed)
        NSLayoutConstraint.activate([
            framed.topAnchor.constraint(equalTo: container.topAnchor),
            framed.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            framed.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            framed.widthAnchor.constraint(equalToConstant: width),
        ])
        return container
    }
}
#endif
