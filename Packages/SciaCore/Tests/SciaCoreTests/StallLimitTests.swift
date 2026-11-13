import SciaTesting
import Testing

struct StallLimitTests {
    private static let limit: Duration = .seconds(60)

    private func run(clock: TestClock, _ body: @Sendable () async throws -> Void) async throws {
        let test = try #require(Test.current)
        try await StallLimitTrait(limit: Self.limit, clock: clock).provideScope(for: test, testCase: nil, performing: body)
    }

    /// 全体が上限より長くかかっても、上限ごとに進み具合が伝わっていれば通す。
    @Test func passesWhileProgressIsNoted() async throws {
        let clock = TestClock()
        try await run(clock: clock) {
            let progress = StallProgress.current
            for step in 0..<3 {
                progress.note("段階\(step)")
                try await clock.advance(afterSleeping: Self.limit)
                // 見張りが、進み具合を数えてから次の待ちに入るのを待つ。待たずに伝えると、次の段階が前の間隔に数えられる。
                try await waitUntil { clock.sleeperCount(remaining: Self.limit) >= 1 }
            }
        }
    }

    /// 上限のあいだ進み具合が伝わらなければ、段階の履歴を失敗に残して、テストをキャンセルする。
    @Test func failsAndCancelsWhenNothingIsNoted() async throws {
        let clock = TestClock()
        let cancelled = Gate()
        await withKnownIssue {
            await #expect(throws: WaitHang.self) {
                try await run(clock: clock) {
                    StallProgress.current.note("最後に進んだ段階")
                    try await clock.advance(afterSleeping: Self.limit)
                    // 進み具合のなかった間隔のあとに、固まったとみなす。
                    try await clock.advance(afterSleeping: Self.limit)
                    do {
                        try await Gate().wait()
                    } catch {
                        cancelled.open()
                        throw error
                    }
                }
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("0.0秒 最後に進んだ段階") }
        }
        #expect(cancelled.isOpen)
    }
}
