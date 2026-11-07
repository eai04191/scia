import Foundation

extension TimelineStore {
    /// `TimelineStore`が持つ状態の全部。テストで、操作の前後の状態を丸ごと比べ、書いていない変化を見逃さないため、1つの値にまとめる。
    /// 状態を足すときは、ストアのプロパティではなくここに足す。ストアに直接持つと、テストの比べる対象から漏れるため。
    struct State: Equatable {
        /// 新しい順。
        var entries: [TimelineEntry] = [] {
            didSet { derived = DerivedIDs() }
        }
        /// これより古い投稿はない。
        var reachedEnd = false
        var isLoading = false
        /// 直近の読み込みで、サーバーがホームを再生成中だった。結果が揃っていないため、時間をおいて読み直す。
        var isRegenerating = false
        /// ストリーミングで届き、まだ挿入していない投稿。届いた順。
        var pending: [Status] = []
        /// 見た中で最も新しい投稿のID。サーバーに保存する既読位置に使う。
        var lastReadID: String?
        /// 見た中でタイムラインの最も上にある位置。これより上の投稿を未読として数える。
        /// 遅れて届いて一番上に積んだ投稿は、IDが`lastReadID`より古くても上にあるため、IDとは別に持つ。
        var lastReadPosition: DisplayPosition?
        #if DEBUG
        /// サーバーに保存できる投稿のうち、見た中で最も新しいもののID。
        var lastSavableReadID: String?
        #endif
        /// サーバーのmarkerに保存されている既読位置。
        var savedReadID: String?
        /// 読み込み中のギャップのID。
        var loadingGapIDs: Set<String> = []
        /// 直近の読み込みに失敗したギャップと、その理由。読み直し始めたら外す。
        var failedGaps: [String: ErrorPresentation] = [:]

        /// 補完を始めたが、まだ成功していない基準のID。失敗した後に新着が挿入されて最新のIDが進んでも、次の補完はここから読む。
        var unfilledSinceID: String?
        var isFilling = false
        /// 補完の最中に再び補完を求められたときの基準のID。今の補完が終わったら、ここからもう一度読む。
        var refillSinceID: String?
        /// タイムラインが空のときに始めた補完が、まだ成功していない。成功するまで、タイムラインに新着が入っても、次の補完は最新のページから読む。
        /// 新着の下にある、切れていた間の投稿を読む基準が、タイムラインにはないため。
        var fillsFromLatestPage = false
        /// タイムラインが空のときに始めた補完の最中に、再び補完を求められた。今の補完が終わったら、読んだページより新しい投稿を読む。
        var refillsAfterLatestPage = false
        /// 読み込んだ中で最も古い投稿のID。その投稿が消えても上げない。続きを古い方へ読む位置と、届いた新着を捨てる境目に使う。
        /// 消えるたびに上げると、タイムラインが空になったときに遅れて届いた古い投稿が末尾になり、その上を読み飛ばすため。
        var oldestLoadedID: String?
        /// ストリーミングで届いた、タイムラインの末尾より古い投稿。古い方を読んで末尾がそれより下がったらタイムラインに入れる。
        /// 古い方のページを読んでいる間に届くと、サーバーが作ったページに入っておらず、捨てるとどこからも読めないため。
        var olderArrivals: [Status] = []
        /// 削除のイベントで消した投稿のID。削除の前に読み始めたRESTの結果に含まれていても、表示に戻さない。
        var deletedIDs: Set<String> = []
        /// ミュートかブロックした相手のアカウントのID。その人の投稿とブーストを除き、あとから届いても足さない。
        var excludedAccountIDs: Set<String> = []
        /// ミュートしたハッシュタグの、`HashtagMute.matchingKey(for:)`の値。
        var excludedTagKeys: Set<String> = []
        /// 読めなかった投稿。同じIDの投稿が読めたら外す。
        var unreadableItems: [UnreadableItem] = []
        /// フィルターで出さない投稿。タイムラインには並べないが、読めなかった投稿と同じく、続きを読む位置には使う。
        /// 1ページの全部が隠れても、その先へ進めるようにするため。編集でフィルターに一致しなくなれば、タイムラインに戻す。
        var hiddenStatuses: [Status] = [] {
            didSet { derived = DerivedIDs() }
        }
        /// 遅れて届いて一番上に積んだ投稿の位置。ここにない投稿は、IDの位置に並べる。
        var lateArrivalPositions: [String: DisplayPosition] = [:] {
            didSet { derived = DerivedIDs() }
        }
        /// 遅れて届いた投稿に振った番号の最後。後に届いた投稿ほど大きい。
        var lateArrivalSequence = 0
        /// 投稿の応答で入れ、まだストリーミングでも補完でも届いていない自分の投稿のID。
        var unconfirmedPostedIDs: Set<String> = []
        /// 並びから作るIDの使い回し。
        var derived = DerivedIDs()
    }

    /// `loadedIDs`と`itemIDs`を、並びが変わるまで使い回す。流れの速いタイムラインでは、届くたびに全件から作り直すと重くなるため。
    /// 並びから作り直せる値なので、状態を比べるときは見ない。比べると、同じ並びでも、使い回しを作ったかどうかでテストが落ちるため。
    struct DerivedIDs: Equatable, CustomReflectable {
        var loadedIDs: Set<String>?
        var itemIDs: [String]?

        static func == (_: DerivedIDs, _: DerivedIDs) -> Bool { true }

        /// テストが状態の違いを`dump`で並べるときに、比べない値を出さない。
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    /// タイムラインの中の位置。IDの位置に並べる投稿は、自分のIDと0。遅れて届いて積んだ投稿は、積んだときに一番上だった投稿のIDと、届いた順の番号。
    /// 同じIDの上では、番号の大きいものほど上に並ぶ。
    struct DisplayPosition: Equatable {
        let anchorID: String
        let sequence: Int

        func isAbove(_ other: DisplayPosition) -> Bool {
            anchorID == other.anchorID ? sequence > other.sequence : StatusID.isNewer(anchorID, than: other.anchorID)
        }
    }
}
