import Foundation
import SciaCore
import UIKit

/// 通知の画面を組み立て、読み込みとストリーミングを受け持つ`NotificationsModel`とTimelineViewControllerをつなぐ。
@MainActor
final class NotificationsController {
    private(set) lazy var viewController = TimelineViewController(texts: .notifications) { [weak model] in await model?.refresh() }
    /// 読み込み、ストリーミング、既読位置を受け持つ。
    let model: NotificationsModel
    /// 未読の数が変わったときに呼ぶ。タブのバッジに出す。2つめの値は、実際はもっと多いかもしれないこと。
    var onUnreadCountChange: ((Int, Bool) -> Void)? {
        get { model.onUnreadCountChange }
        set { model.onUnreadCountChange = newValue }
    }
    /// ストリーミングで新しい通知が届いたときに呼ぶ。ステータスバーに流す。2つめの値は、通知の投稿に当てたサーバーのフィルターの判定。
    var onArrival: ((MastodonNotification, FilterVerdict) -> Void)? {
        get { model.onArrival }
        set { model.onArrival = newValue }
    }
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { model.runningTaskCount }
    /// 通知のタイムラインを最初から読み込んだとき、引っぱって読み直したときに呼ぶ。保留中の通知の人数を読み直すのに使う。
    var onReload: () -> Void {
        get { model.onReload }
        set { model.onReload = newValue }
    }
    /// 通知のタイムラインを最上部からさらに引っぱったときに見せる、ストリーミングの状態。
    private let streamingStatusView = StreamingStatusPullView()
    /// 開いている、保留中の通知の1人分の画面。通知のタイムラインと同じく、投稿の操作や削除を反映する。
    private let accountScreens = NSHashTable<AccountNotificationsController>.weakObjects()

    init(
        session: AccountSession,
        tuning: TuningStore = AppDependencies.tuning,
        clock: any Clock<Duration> = AppDependencies.clock,
        now: @escaping () -> Date = AppDependencies.now
    ) {
        model = NotificationsModel(session: session, tuning: tuning, clock: clock, now: now, backgroundTime: BackgroundTime.request)
        model.display = viewController
        model.streamingStatus = streamingStatusView
        #if DEBUG
        model.isHoldingArrivals = { DebugFaults.isHoldingArrivals }
        #endif
        viewController.filterWarnings = FilterWarnings(filtering: model.filtering)
        viewController.onApproachingEnd = { [weak model] in model?.approachEnd() }
        viewController.onRetry = { [weak model] in model?.retry() }
        viewController.onGapSelect = { [weak model] id, direction in model?.selectGap(id, from: direction) }
        viewController.onVisibleNotificationsChange = { [weak model] ids in model?.markRead(ids) }
        viewController.onInteractionSettle = { [weak model] in model?.interactionDidSettle() }
        streamingStatusView.install(in: viewController.collectionView)
    }

    /// - Parameter purpose: 使う人が開いたときは`.action`。電波の回復などでやり直すときは`.display`。レート制限で止められている間は送らない。
    func start(purpose: RequestPurpose) {
        model.start(purpose: purpose)
    }

    /// まだ始めていなければ始める。無効にしていて起動のときに始めなかった通知を、有効にしたときに始めるのに使う。
    func startIfNeeded() {
        model.startIfNeeded()
    }

    /// 設定で有効か無効かを切り替える。
    func setEnabled(_ isEnabled: Bool) {
        model.setEnabled(isEnabled)
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。セッションを閉じたときは、呼ばなくても持ち主が閉じて止まる。
    func stop() {
        model.stop()
    }

    /// バックグラウンドに入るときに呼ぶ。
    func enterBackground() {
        model.enterBackground()
    }

    /// バックグラウンドから戻ったときに呼ぶ。
    func enterForeground() {
        model.enterForeground()
    }

    /// ストリーミングの接続の状態を、引っぱったときに見せる表示へ伝える。
    func showStreamingState(_ state: ConnectionDiagnostics.StreamingState?) {
        model.showStreamingState(state)
    }

    #if DEBUG
    /// `scia-debug://inject/notifications`で読んだ通知を、ストリーミングで届いた通知と同じ経路で流す。
    func inject(_ notifications: [MastodonNotification]) {
        model.inject(notifications)
    }

    /// `scia-debug://arrivals/release`で保留を解いたとき。
    func releaseHeldArrivals() {
        model.releaseHeldArrivals()
    }
    #endif

    /// 保留中の通知の1人分の画面を開いた。閉じるまで、投稿の操作や削除を反映する。
    func track(_ screen: AccountNotificationsController) {
        accountScreens.add(screen)
    }

    /// 保留中の通知を受け入れた。サーバーが取り込み終えたら通知のタイムラインを読み直す。
    func didAcceptRequest() {
        model.didAcceptRequest()
    }

    /// お気に入りなどの操作の結果を反映する。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        model.updateStatus(id, transform)
        for screen in accountScreens.allObjects {
            screen.updateStatus(id, transform)
        }
    }

    /// 削除した投稿についての通知を除く。
    func removeStatus(_ id: Status.ID) {
        model.removeStatus(id)
        for screen in accountScreens.allObjects {
            screen.removeStatus(id)
        }
    }

    /// ミュートしたハッシュタグの付いた投稿の通知を除く。
    func setTag(_ name: String, excluded: Bool) {
        model.setTag(name, excluded: excluded)
        for screen in accountScreens.allObjects {
            screen.setTag(name, excluded: excluded)
        }
    }

    /// 通知を隠すミュートか、ブロックをした相手からの通知を除く。
    func setAccount(_ id: String, excluded: Bool) {
        model.setAccount(id, excluded: excluded)
        for screen in accountScreens.allObjects {
            screen.setAccount(id, excluded: excluded)
        }
    }

    /// 使う人が削除した通知を除く。
    func removeNotification(_ notification: MastodonNotification) {
        model.removeNotification(notification)
        for screen in accountScreens.allObjects {
            screen.removeNotification(notification)
        }
    }

    /// 片づけたフォローリクエストの通知と、同じユーザーからのリクエストの通知を除く。
    func removeFollowRequests(answering request: MastodonNotification) {
        model.removeFollowRequests(answering: request)
        for screen in accountScreens.allObjects {
            screen.removeFollowRequests(answering: request)
        }
    }
}
