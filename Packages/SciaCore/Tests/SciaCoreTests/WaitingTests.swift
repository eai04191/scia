@testable import SciaTesting
import Testing

@MainActor
struct WaitingTests {
    /// 上限を過ぎた待ちは、失敗を残すだけで戻らず、投げてテストを終える。戻ると、固まったテストが続く待ちのたびに上限まで待つ。
    @Test func throwsWhenLimitPasses() async {
        var thrown: (any Error)?
        await withKnownIssue("上限を過ぎた待ちは失敗を残す") {
            do {
                try await waitUntil(limit: .zero) { false }
            } catch {
                thrown = error
            }
        }
        #expect(thrown is WaitHang)
    }

    /// 上限を過ぎた待ちは、残す失敗に、渡した状態を添える。
    @Test func recordsStateWhenLimitPasses() async {
        await withKnownIssue("上限を過ぎた待ちは失敗を残す") {
            try? await waitUntil(limit: .zero, state: { "loading: 1" }) { false }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("loading: 1") }
        }
    }

    /// メインのRunLoopが手すきになるのを待つ上限を過ぎても、投げる。戻ると、層の時計は外れない動きがないかぎり次のコマへ進み、コマごとに上限まで待つ。
    @Test func mainRunLoopWaitThrowsWhenLimitPasses() async {
        var thrown: (any Error)?
        await withKnownIssue("上限を過ぎた待ちは失敗を残す") {
            do {
                try await waitUntilMainRunLoopIsIdle(limit: .zero)
            } catch {
                thrown = error
            }
        }
        #expect(thrown is WaitHang)
    }
}
