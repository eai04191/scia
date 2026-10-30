import Foundation

/// 一覧全体の状態。投稿がないときの表示に使う。
public enum TimelineContentState: Equatable, Sendable {
    case loading
    case loaded
    /// サーバーがホームを再生成中で、まだ投稿が返ってこない。
    case regenerating
    case failed(ErrorPresentation)
}

/// 末尾の読み込みの状態。フッターに出す。
public enum TimelineFooterState: Equatable, Sendable {
    case idle
    case loading
    case failed(ErrorPresentation)
    case reachedEnd
}

/// 一覧の画面への命令。読み込み、ストリーミング、既読位置を受け持つ側（`FeedTimelineModel`など）が、結果を画面へ伝えるのに使う。
/// iOSでは`TimelineViewController`が従う。スクロール位置の指定は一度きりの命令なので、状態として渡さず、並びを渡す命令に添える。
@MainActor
public protocol TimelineDisplay: AnyObject {
    /// 表示中の行を、新しい順に並んだ`entries`で置き換える。読んでいる位置の行は、画面上で動かさない。
    /// - Parameter anchorID: 位置を保つ行。nilなら、表示領域の上端にかかっている行。最上部にいれば、最上部に留まって新着を見せる。
    /// - Parameter topID: 表示領域の上端に置く行。既読位置から読み始めるときに使う。
    /// - Parameter keepsOffset: 行を基準にせず、スクロール位置をそのまま保つ。
    /// - Parameter animatesRemoval: 使う人の操作で行を消した。消える行を閉じる動きで消す。
    /// - Parameter base: `entries`は、この並びに行を足すか除くかしただけで、残る行の中身を変えていない。
    func setEntries(_ entries: [TimelineEntry], keeping anchorID: TimelineEntry.ID?, placingAtTop topID: TimelineEntry.ID?, keepsOffset: Bool, animatesRemoval: Bool, keepingRowContentsOf base: [TimelineEntry]?)
    func setContentState(_ state: TimelineContentState)
    func setFooterState(_ state: TimelineFooterState)
    /// 読み込み中のギャップを読み込み中の表示に、読めなかったギャップを読めなかった表示にする。
    func setGapStates(loading ids: Set<String>, failures: [String: ErrorPresentation])
    /// 既読より新しい行の数。0なら新着のボタンを隠す。
    /// - Parameter isLowerBound: 未読の区間に読み込んでいない行があり、実際はもっと多い。
    func setUnreadCount(_ count: Int, isLowerBound: Bool)
    /// ストリーミングにつながらない状態が続いていることを出すか。
    func setOutageNotice(_ isShown: Bool)
    /// 挿入までに読み終えられるよう、行のアイコンを読み始める。
    func prefetchAvatars(of entries: [TimelineEntry])
    /// `entries`が返す行のアイコンを読み込み終えるまで、`timeout`を上限に待つ。
    func waitForAvatars(of entries: () -> [TimelineEntry], within timeout: Duration) async
    /// スクロールしている、または長押しのメニューを出している。新着を挿入するのは、これが終わってからにする。
    var isUserInteracting: Bool { get }
    /// 表示領域の上端にかかっている、最も上の行。
    func currentAnchorID() -> TimelineEntry.ID?
}

/// 一覧を最上部からさらに引っぱったときに見せる、ストリーミングの状態の表示への命令。
@MainActor
public protocol StreamingStatusDisplay: AnyObject {
    func setState(_ state: ConnectionDiagnostics.StreamingState?)
    /// 切れていた間の行を読む補完の状態。
    func setCatchUp(_ status: CatchUpStatus)
    /// ストリーミングで届いた新着の流れの速さ。
    func setArrivalRate(_ rate: ArrivalRate)
}

extension TimelineDisplay {
    /// 並びを渡す命令を、指定しない項目を既定にして送る。
    func show(_ entries: [TimelineEntry], keeping anchorID: TimelineEntry.ID? = nil, placingAtTop topID: TimelineEntry.ID? = nil, animatesRemoval: Bool = false, keepingRowContentsOf base: [TimelineEntry]? = nil) {
        setEntries(entries, keeping: anchorID, placingAtTop: topID, keepsOffset: false, animatesRemoval: animatesRemoval, keepingRowContentsOf: base)
    }
}
