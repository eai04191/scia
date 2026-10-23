#if DEBUG
import SciaCore
import UIKit

/// 一覧を最上部からさらに引っぱったときに見せる、ストリーミングとRESTの状態（`StreamingStatusPullView`）。
/// 本物は引っぱった分だけ薄く出るため、カタログでは濃さを変えずに置く。
enum StreamingStatusCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "ふだん（接続中・最新）") { status(.connected, catchUp: loaded(), arrivals: 12) },
            CatalogState(title: "流れが速い") { status(.connected, catchUp: loaded(), arrivals: 1_234) },
            CatalogState(title: "最新（今日より前に読んだ）") { status(.connected, catchUp: loaded(at: Date(timeIntervalSinceNow: -86_400))) },
            CatalogState(title: "最初の読み込みの前・未接続") { status(nil, catchUp: CatchUpStatus()) },
            CatalogState(title: "接続待ち") { status(.connecting, catchUp: loaded()) },
            CatalogState(title: "つながって読み込み中") { status(.connected, catchUp: loading(readCount: 80)) },
            CatalogState(title: "ポーリングで読み込み中（読み始め）") { status(.polling, catchUp: loading(readCount: 0)) },
            CatalogState(title: "停止中（バックグラウンドなど。画面には出ない）") { status(.stopped, catchUp: loaded()) },
            CatalogState(title: "ログインが必要") { status(.loginRequired, catchUp: loaded()) },
            CatalogState(title: "サーバーがホームを作り直し中") {
                var catchUp = loaded()
                catchUp.finish(at: Date(), isRegenerating: true)
                return status(.connected, catchUp: catchUp)
            },
            CatalogState(title: "読み込みに失敗") {
                var catchUp = loading(readCount: 0)
                catchUp.fail(URLError(.timedOut))
                return status(.connected, catchUp: catchUp)
            },
            CatalogState(title: "レート制限で待機中（いちばん長い文言、狭い幅）") {
                var catchUp = loading(readCount: 0)
                catchUp.fail(AutomaticRequestsPaused(until: Date(timeIntervalSinceNow: 300)))
                return status(.polling, catchUp: catchUp, width: 260)
            },
        ]
    }

    private static func loaded(at date: Date = Date()) -> CatchUpStatus {
        var catchUp = CatchUpStatus()
        catchUp.finish(at: date)
        return catchUp
    }

    private static func loading(readCount: Int) -> CatchUpStatus {
        var catchUp = loaded(at: Date(timeIntervalSinceNow: -600))
        catchUp.begin()
        catchUp.progress(readCount: readCount)
        return catchUp
    }

    @MainActor
    private static func status(
        _ state: ConnectionDiagnostics.StreamingState?,
        catchUp: CatchUpStatus,
        arrivals: Int = 0,
        width: CGFloat? = nil
    ) -> UIView {
        let view = StreamingStatusPullView()
        view.setState(state)
        view.setCatchUp(catchUp)
        var rate = ArrivalRate()
        let now = Date()
        for _ in 0..<arrivals {
            rate.record(at: now)
        }
        view.setArrivalRate(rate)
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
