import SciaCore
import SciaTesting
import Synchronization
import Testing
@testable import Scia

/// 絵文字ピッカーのサムネイルを、絵文字ピッカーを閉じている間に裏で作る仕組み。
@MainActor
@Suite(.failureState)
struct EmojiThumbnailBuilderTests {
    /// 作る処理の代わり。始めた回ごとに門を作り、開けるまで終わらない。止められても、開けるまで終わらない（展開の途中で止められた形）。
    private final class Builds: Sendable {
        private struct Run {
            let gate = Gate()
            var cancelled = false
            var isWatchingCancellation = false
        }

        private let runs = Mutex<[Run]>([])

        func run() async {
            let (index, gate) = runs.withLock { runs in
                runs.append(Run())
                return (runs.count - 1, runs[runs.count - 1].gate)
            }
            // 門は取り消されると待つのをやめるので、取り消されない別の処理で待ち、止められても開けるまで終わらないようにする。
            await withTaskCancellationHandler {
                // 止められたことを記録できるようになってから、始めたと数える。数える前に止められると、記録が止めたあとに遅れて付くため。
                runs.withLock { $0[index].isWatchingCancellation = true }
                await Task(.withoutRequests) { try? await gate.wait() }.value
            } onCancel: {
                runs.withLock { $0[index].cancelled = true }
            }
        }

        var count: Int { runs.withLock { $0.count { $0.isWatchingCancellation } } }
        var cancelled: [Bool] { runs.withLock { $0.map(\.cancelled) } }
        func open(_ index: Int) { runs.withLock { $0[index].gate }.open() }
    }

    /// 止めた作業が終わる前に、絵文字ピッカーを閉じて作業を始め直しても、あとで始めた作業を絵文字ピッカーを開いたときに止められる。
    /// 止めた作業が終わるときに、あとで始めた作業の控えを消していたため、絵文字ピッカーを開いても作り続けていた。
    @Test func keepsHandleOfRestartedBuildWhenCancelledBuildFinishes() async throws {
        let builds = Builds()
        let builder = EmojiThumbnailBuilder(build: { await builds.run() }, buildWhileShown: {})
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
        #expect(builds.cancelled == [true, true])
        builds.open(1)
        try await waitUntil { builder.finishedCount >= 2 }
    }

    /// 絵文字ピッカーが開いている間は、Unicodeの絵文字の小さい画像だけを作り、閉じたら止めて、閉じている間の作業に替える。
    @Test func buildsSmallGlyphsOnlyWhileShown() async throws {
        let builds = Builds()
        let shown = Builds()
        let builder = EmojiThumbnailBuilder(build: { await builds.run() }, buildWhileShown: { await shown.run() })

        builder.paletteDidAppear()
        try await waitUntil { shown.count >= 1 }
        #expect(builder.isBuildingWhileShown)
        #expect(!builder.isBuilding)

        builder.paletteDidDisappear()
        #expect(!builder.isBuildingWhileShown)
        #expect(shown.cancelled == [true])
        try await waitUntil { builds.count >= 1 }
        shown.open(0)
        builds.open(0)
        try await waitUntil { builder.finishedCount >= 1 }
    }

    /// 絵文字ピッカーが開いている間は、作り始めない。
    @Test func doesNotStartWhilePaletteIsShown() {
        let builds = Builds()
        let builder = EmojiThumbnailBuilder(build: { await builds.run() }, buildWhileShown: {})
        builder.paletteDidAppear()

        builder.start()

        #expect(!builder.isBuilding)
    }
}
