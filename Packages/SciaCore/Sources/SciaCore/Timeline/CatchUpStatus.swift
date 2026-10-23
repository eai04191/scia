public import Foundation

/// ストリーミングが切れていた間の投稿や通知を読む補完の、直近の状態。一覧を引っぱったときに見せる。
/// つながっていても、補完がまだ終わっていなければ新着は出てこないため、ストリーミングの状態とは別に持つ。
public struct CatchUpStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// 読んでいない。最初の読み込みの前か、直近の補完が済んだ。
        case idle
        /// 読んでいる。何ページ読めば終わるかはサーバーが返さないため、全体は分からず、読んだ件数だけを持つ。
        case loading(readCount: Int)
        /// サーバーがホームを作り直している最中で結果が揃っておらず、時間をおいて読み直す。
        case regenerating
        /// 短い間にリクエストが多すぎてサーバーに止められ、自動の通信を控えている。明けたら読み直す。
        case paused(until: Date)
        /// 直近の補完に失敗した。次につながったときなどに、同じ基準から読み直す。
        case failed(ErrorPresentation)
    }

    public private(set) var phase: Phase = .idle
    /// 最新の側まで読み終えた時刻。最初の読み込みも含む。作り直し中で揃っていなかった読み込みは含めない。
    public private(set) var lastLoadedAt: Date?
    /// 補完を始めるたびに進む番号。補完の最中に次の補完を求められても、今の補完が続けて読むので進めない。
    public private(set) var attempt = 0

    public init() {}

    /// 補完の最中に次の補完を求められても、ストアは今の補完で続けて読むので、読んだ件数はそのまま積み上げる。
    public mutating func begin() {
        if case .loading = phase { return }
        attempt += 1
        phase = .loading(readCount: 0)
    }

    /// 読んでいる間に、読んだ件数を進める。読んでいなければ何もしない。
    public mutating func progress(readCount: Int) {
        guard case .loading = phase else { return }
        phase = .loading(readCount: readCount)
    }

    /// - Parameter isRegenerating: サーバーがホームを作り直している最中で、結果が揃っていなかった。
    public mutating func finish(at date: Date, isRegenerating: Bool = false) {
        if isRegenerating {
            phase = .regenerating
        } else {
            phase = .idle
            lastLoadedAt = date
        }
    }

    /// `attempt`番の補完が終わった後で、自動の通信を控えていると分かったら、待機中にする。
    /// 補完そのものが429や503を受けて止められると、控えていることで投げられた失敗ではないので、失敗としか分からない。
    /// 2ページ目以降で止められると、補完は読めた分で終わり、残りをギャップにする。最新の側は読めているので時刻はそのまま。どちらも明ければ読み直す。
    /// 控えているかは終えた後に確かめるので、その間に次の補完が始まっていたら、新しい状態を上書きしない。
    public mutating func pause(after attempt: Int, until: Date) {
        guard attempt == self.attempt else { return }
        switch phase {
        case .idle, .failed:
            phase = .paused(until: until)
        case .loading, .regenerating, .paused:
            break
        }
    }

    /// 取り消しは失敗として見せない。読み込みを打ち切った画面のもので、読めなかったわけではないため。
    public mutating func fail(_ error: any Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            phase = .idle
        } else if let paused = error as? AutomaticRequestsPaused {
            phase = .paused(until: paused.until)
        } else {
            phase = .failed(ErrorPresentation(error))
        }
    }
}
