import Foundation
import os
import SciaCore
import UIKit

/// ホームや公開タイムラインの画面を組み立て、読み込みとストリーミングを受け持つ`FeedTimelineModel`とTimelineViewControllerをつなぐ。
/// タブのタイムラインのほか、開いたタイムラインに積むハッシュタグのタイムラインにも使う。
@MainActor
final class FeedTimelineController {
    private(set) lazy var viewController = TimelineViewController(texts: texts) { [weak model] in await model?.refresh() }
    private let texts: TimelineViewController.Texts
    /// 読み込み、ストリーミング、既読位置を受け持つ。
    let model: FeedTimelineModel
    var feed: TimelineFeed { model.feed }
    let client: MastodonClient
    let tuning: TuningStore
    let logger = SciaLog.logger(category: "timeline")
    /// 走り終えていない読み込みなどの処理の数。止めたものも、取り消しを受けて戻り切るまで数える。止めたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { model.runningTaskCount }
    /// タイムラインのストリームを購読している。
    var isSubscribedToStreaming: Bool { model.isSubscribedToStreaming }
    /// タイムラインを最上部からさらに引っぱったときに見せる、ストリーミングの状態。
    private let streamingStatusView = StreamingStatusPullView()
    #if DEBUG
    /// ダミー投稿の「ステータスバーの通知」が選ばれたとき。通知はホームのタイムラインではなく、ステータスバーに流す。
    var onDummyNotifications: (() -> Void)?
    /// デバッグメニューの「ステータスバーの通知を出し続ける」を切り替えたとき。渡す値は切り替えたあとの状態。
    var onSetStatusBarTickerLooping: ((Bool) -> Void)?
    /// ステータスバーの通知を出し続けているか。デバッグメニューのチェックマークに使う。
    var isStatusBarTickerLooping: (() -> Bool)?
    #endif
    /// 走っている補完が終わるのを待っている、引っぱった読み直しの数。テストで、待ち始めたことを時間を待たずに確かめる。
    var fillWaiterCount: Int { model.fillWaiterCount }

    init(
        feed: TimelineFeed,
        texts: TimelineViewController.Texts? = nil,
        session: AccountSession,
        tuning: TuningStore = AppDependencies.tuning,
        clock: any Clock<Duration> = AppDependencies.clock,
        now: @escaping () -> Date = AppDependencies.now
    ) {
        model = FeedTimelineModel(feed: feed, session: session, tuning: tuning, clock: clock, now: now, backgroundTime: BackgroundTime.request)
        self.texts = texts ?? Self.texts(for: feed)
        self.client = session.client
        self.tuning = tuning
        model.display = viewController
        model.streamingStatus = streamingStatusView
        #if DEBUG
        model.isHoldingArrivals = { DebugFaults.isHoldingArrivals }
        #endif
        viewController.filterWarnings = FilterWarnings(filtering: model.filtering)
        viewController.onApproachingEnd = { [weak model] in model?.approachEnd() }
        viewController.onRetry = { [weak model] in model?.retry() }
        viewController.onVisibleStatusesChange = { [weak model] ids in model?.markRead(ids) }
        viewController.onInteractionSettle = { [weak model] in model?.interactionDidSettle() }
        streamingStatusView.install(in: viewController.collectionView)
        viewController.onGapSelect = { [weak model] id, direction in model?.selectGap(id, from: direction) }
        viewController.onGapApproach = { [weak model] id, direction in model?.approachGap(id, from: direction) }
        viewController.onVisibilityChange = { [weak model] isShown in model?.setShown(isShown) }
        #if DEBUG
        viewController.debugActions = makeDebugActions()
        #endif
        model.onStop { [weak viewController] in
            // 積んで開いたタイムラインは、画面がこのコントローラーを生かしているため、持ち合いを解いて捨てられるようにする。
            viewController?.lifetimeOwner = nil
        }
    }

    /// - Parameter purpose: 使う人が開いたときは`.action`。電波の回復などでやり直すときは`.display`。レート制限で止められている間は送らない。
    func start(purpose: RequestPurpose) {
        model.start(purpose: purpose)
    }

    private static func texts(for feed: TimelineFeed) -> TimelineViewController.Texts {
        switch feed {
        case .home: .home
        case .local: .local
        case .federated: .federated
        // リストの名前は、作る側が`texts`で渡す。
        case .list: .list(title: "")
        case .hashtag(let name): .hashtag(name: name)
        // ユーザーの名前は、作る側が`texts`で渡す。
        case .accountHashtag(_, let name): .accountHashtag(name: name, acct: "")
        }
    }

    /// まだ始めていなければ始める。開くまで読まないタイムラインを、初めて開いたときに始めるのに使う。
    func startIfNeeded() {
        model.startIfNeeded()
    }

    #if DEBUG
    /// 始めているタイムラインだけ読み込み直す。障害を起こすデバッグURLで、開いたことのないタイムラインまで読み始めないようにする。
    func reloadIfStarted() {
        model.reloadIfStarted()
    }
    #endif

    /// 設定で有効か無効かを切り替える。
    func setEnabled(_ isEnabled: Bool) {
        model.setEnabled(isEnabled)
    }

    /// サーバーがこのタイムラインを読ませないと分かったときに呼ぶ（docs/tabs.md）。
    func markUnavailableOnServer() {
        model.markUnavailableOnServer()
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときと、積んで開いたタイムラインがナビゲーションから外されたときに呼ぶ。
    /// セッションを閉じたときは、呼ばなくても持ち主が閉じて止まる。
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
    /// `scia-debug://arrivals/release`で保留を解いたとき。
    func releaseHeldArrivals() {
        model.releaseHeldArrivals()
    }
    #endif

    /// ミュートしたハッシュタグの付いた投稿とブーストを除く。
    func setTag(_ name: String, excluded: Bool) {
        model.setTag(name, excluded: excluded)
    }

    /// ミュートかブロックした相手の投稿とブーストを除く。
    func setAccount(_ id: String, excluded: Bool) {
        model.setAccount(id, excluded: excluded)
    }
}
