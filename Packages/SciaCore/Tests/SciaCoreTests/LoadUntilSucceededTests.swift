import Testing
@testable import SciaCore

@MainActor
struct LoadUntilSucceededTests {
    private struct Failure: Error {}

    /// 端末のロック中にKeychainを読めなかったときのように、失敗は覚えず、次に使うときに読み直す。読めたら、そのあとは読み直さない。
    @Test func retriesAfterFailureAndKeepsSuccess() {
        var attempts = 0
        let load = LoadUntilSucceeded<Int> {
            attempts += 1
            guard attempts > 1 else { throw Failure() }
            return attempts
        }

        #expect((try? load.get().get()) == nil)
        #expect((try? load.get().get()) == 2)
        #expect((try? load.get().get()) == 2)
        #expect(attempts == 2)
    }
}
