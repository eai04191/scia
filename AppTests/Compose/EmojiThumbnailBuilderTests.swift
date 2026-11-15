import SciaCore
import SciaTesting
import Synchronization
import Testing
@testable import Scia

/// 絵文字ピッカーの小さい静止画を、絵文字ピッカーを閉じている間に裏で作る仕組み。
@MainActor
@Suite(.failureState)
struct EmojiThumbnailBuilderTests {
    /// 作る処理の代わり。始めた回ごとに門を作り、開けるまで終わらない。止められても、開けるまで終わらない（展開の途中で止められた形）。
    private final class Builds: Sendable {
        let gates = Mutex<[Gate]>([])
        let cancelled = Mutex<[Bool]>([])

        func run() async {
            let gate = Gate()
            let index = gates.withLock { gates in
                gates.append(gate)
                return gates.count - 1
            }
            cancelled.withLock { $0.append(false) }
            // 門は取り消されると待つのをやめるので、取り消されない別の処理で待ち、止められても開けるまで終わらないようにする。
            await withTaskCancellationHandler {
                await Task(.withoutRequests) { try? await gate.wait() }.value
            } onCancel: {
                cancelled.withLock { $0[index] = true }
            }
        }

        var count: Int { gates.withLock { $0.count } }
        func open(_ index: Int) { gates.withLock { $0[index] }.open() }
    }

    /// 止めた作業が終わる前に、絵文字ピッカーを閉じて作業を始め直しても、あとで始めた作業を絵文字ピッカーを開いたときに止められる。
    /// 止めた作業が終わるときに、あとで始めた作業の控えを消していたため、絵文字ピッカーを開いても作り続けていた。
    @Test func keepsHandleOfRestartedBuildWhenCancelledBuildFinishes() async throws {
        let builds = Builds()
        let builder = EmojiThumbnailBuilder { await builds.run() }
        builder.start()
        try await waitUntil { builds.count >= 1 }

        builder.paletteDidAppear()
        builder.paletteDidDisappear()
        try await waitUntil { builds.count >= 2 }
        builds.open(0)
        try await waitUntil { builder.finishedCount >= 1 }

        #expect(builder.isBuilding, "あとで始めた作業は、まだ作っている")
        builder.paletteDidAppear()
        #expect(!builder.isBuilding)
        #expect(builds.cancelled.withLock { $0 } == [true, true])
        builds.open(1)
        try await waitUntil { builder.finishedCount >= 2 }
    }

    /// 絵文字ピッカーが開いている間は、作り始めない。
    @Test func doesNotStartWhilePaletteIsShown() {
        let builds = Builds()
        let builder = EmojiThumbnailBuilder { await builds.run() }
        builder.paletteDidAppear()

        builder.start()

        #expect(!builder.isBuilding)
    }
}
