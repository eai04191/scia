import SciaCore
import SciaTesting
import Synchronization
import Testing
@testable import Scia

/// 端末に残した`api/v1/custom_emojis`の応答が変わったら、端末に置く絵文字の画像を分け直し、先読みする仕組み。
@MainActor
@Suite(.failureState)
struct EmojiPrefetcherTests {
    /// 分け直しと先読みの代わり。始めた回ごとに、先読みしたかと門を残し、門を開けるまで終わらない。
    private final class Runs: Sendable {
        let gates = Mutex<[Gate]>([])
        let prefetches = Mutex<[Bool]>([])

        func run(prefetches: Bool) async {
            let gate = Gate()
            gates.withLock { $0.append(gate) }
            self.prefetches.withLock { $0.append(prefetches) }
            try? await gate.wait()
        }

        var count: Int { gates.withLock { $0.count } }
        func open(_ index: Int) { gates.withLock { $0[index] }.open() }
    }

    /// 起動したときは分け直すだけで取得しない。応答を読んだときに先読みし、終えたら小さい静止画をまとめて作る処理を始める。
    @Test func prefetchesOnlyWhenListsChange() async throws {
        let runs = Runs()
        let finished = Mutex(0)
        let prefetcher = EmojiPrefetcher(run: { await runs.run(prefetches: $0) }, didFinish: { finished.withLock { $0 += 1 } })

        prefetcher.start()
        try await waitUntil { runs.count >= 1 }
        runs.open(0)
        try await waitUntil { !prefetcher.isRunning }
        #expect(finished.withLock { $0 } == 0)

        prefetcher.listsChanged()
        try await waitUntil { runs.count >= 2 }
        runs.open(1)
        try await waitUntil { !prefetcher.isRunning }

        #expect(runs.prefetches.withLock { $0 } == [false, true])
        #expect(finished.withLock { $0 } == 1)
    }

    /// 先読みの途中で応答がまた変わったら、途中の作業を止めて初めからやり直す。止めた作業が終わっても、やり直した作業の控えは消さない。
    @Test func restartsWhenListsChangeDuringPrefetch() async throws {
        let runs = Runs()
        let finished = Mutex(0)
        let prefetcher = EmojiPrefetcher(run: { await runs.run(prefetches: $0) }, didFinish: { finished.withLock { $0 += 1 } })
        prefetcher.listsChanged()
        try await waitUntil { runs.count >= 1 }

        prefetcher.listsChanged()
        try await waitUntil { runs.count >= 2 }
        runs.open(0)

        #expect(prefetcher.isRunning, "やり直した作業は、まだ途中")
        runs.open(1)
        try await waitUntil { !prefetcher.isRunning }
        #expect(finished.withLock { $0 } == 1)
    }
}
