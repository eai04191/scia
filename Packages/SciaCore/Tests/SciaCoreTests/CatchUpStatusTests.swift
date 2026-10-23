import Foundation
import Testing
@testable import SciaCore

/// 補完の直近の状態と、最新の側まで読み終えた時刻。読み終えた時刻は、揃った結果を読めたときだけ進める。
struct CatchUpStatusTests {
    private let first = Date(timeIntervalSince1970: 1_800_000_000)
    private let second = Date(timeIntervalSince1970: 1_800_000_060)

    @Test func finishRecordsLoadedTime() {
        var status = CatchUpStatus()
        status.begin()
        #expect(status.phase == .loading(readCount: 0))
        status.progress(readCount: 40)
        #expect(status.phase == .loading(readCount: 40))

        status.finish(at: first)

        #expect(status.phase == .idle)
        #expect(status.lastLoadedAt == first)
    }

    /// 失敗しても、前に読み終えた時刻は残す。いつまでの投稿が出ているかは変わらないため。
    @Test func failureKeepsLastLoadedTime() {
        var status = CatchUpStatus()
        status.finish(at: first)
        status.begin()

        status.fail(URLError(.notConnectedToInternet))

        #expect(status.phase == .failed(ErrorPresentation(URLError(.notConnectedToInternet))))
        #expect(status.lastLoadedAt == first)
    }

    /// 作り直し中の結果は揃っていないため、読み終えたことにしない。
    @Test func regeneratingDoesNotAdvanceLoadedTime() {
        var status = CatchUpStatus()
        status.finish(at: first)
        status.begin()

        status.finish(at: second, isRegenerating: true)

        #expect(status.phase == .regenerating)
        #expect(status.lastLoadedAt == first)
    }

    /// 遅れて届いた件数で、済んだ状態を読み込み中に戻さない。
    @Test func progressAfterFinishIsIgnored() {
        var status = CatchUpStatus()
        status.begin()
        status.finish(at: first)

        status.progress(readCount: 40)

        #expect(status.phase == .idle)
    }

    /// レート制限で止められたのは失敗ではなく、明けたら読み直すので、いつまで控えるかを持つ。
    @Test func rateLimitPauses() {
        var status = CatchUpStatus()
        status.begin()

        status.fail(AutomaticRequestsPaused(until: second))

        #expect(status.phase == .paused(until: second))
    }

    /// 2ページ目以降で止められても、最新の側は読めているので時刻は進め、待機中と出す。
    @Test func pauseAfterLoadingKeepsLoadedTime() {
        var status = CatchUpStatus()
        status.begin()
        status.finish(at: first)

        status.pause(after: status.attempt, until: second)

        #expect(status.phase == .paused(until: second))
        #expect(status.lastLoadedAt == first)
    }

    /// 補完そのものが429を受けて止められたときも、失敗ではなく待機中にする。
    @Test func pauseAfterFailure() {
        var status = CatchUpStatus()
        status.begin()
        status.fail(URLError(.badServerResponse))

        status.pause(after: status.attempt, until: second)

        #expect(status.phase == .paused(until: second))
    }

    /// 控えているかを確かめている間に次の補完が始まっていたら、その状態を待機中で上書きしない。終わったあとも上書きしない。
    @Test func pauseAfterNextFillBeganIsIgnored() {
        var status = CatchUpStatus()
        status.begin()
        status.finish(at: first)
        let finished = status.attempt
        status.begin()

        status.pause(after: finished, until: second)
        #expect(status.phase == .loading(readCount: 0))

        status.finish(at: second)
        status.pause(after: finished, until: second)
        #expect(status.phase == .idle)
    }

    /// 補完の最中に次の補完を求められても、今の補完が続けて読むので、読んだ件数を0に戻さない。
    @Test func beginWhileLoadingKeepsReadCount() {
        var status = CatchUpStatus()
        status.begin()
        status.progress(readCount: 40)

        status.begin()

        #expect(status.phase == .loading(readCount: 40))
    }

    @Test(arguments: [CancellationError() as any Error, URLError(.cancelled)])
    func cancellationIsNotFailure(error: any Error) {
        var status = CatchUpStatus()
        status.begin()

        status.fail(error)

        #expect(status.phase == .idle)
    }
}
