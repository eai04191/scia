import SciaCore
import Testing

/// テストの本文から送る通信の目的を名乗るトレイト。クライアントやストアのように、目的を名乗らない層を直接呼ぶテストに付ける。
/// 目的を自分で名乗るもの（モデル、`StatusRefresher`、`XPostStore`など）を確かめるテストには付けない。名乗り忘れを見逃すため。
struct RequestPurposeTrait: SuiteTrait, TestTrait, TestScoping {
    let purpose: RequestPurpose

    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await RequestPurpose.$current.withValue(purpose) {
            try await function()
        }
    }
}

extension Trait where Self == RequestPurposeTrait {
    /// テストの本文から送る通信を、`purpose`と名乗って送る。
    static func requestPurpose(_ purpose: RequestPurpose) -> Self {
        RequestPurposeTrait(purpose: purpose)
    }
}
