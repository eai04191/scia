import SciaTesting
import Testing

@MainActor
struct ExpectChangesTests {
    private struct Failure: Error {}

    @Test func passesWhenOnlyWrittenChangesHappen() async throws {
        var value = (count: 0, label: "a")
        let result = try await expectChanges(of: { [value.count, value.label.count] }, during: { () -> Int in
            value.count = 2
            return value.count
        }) {
            $0[0] = 2
        }
        #expect(result == 2)
    }

    @Test func reportsUnwrittenChange() async throws {
        var value = 0
        await withKnownIssue {
            try await expectChanges(of: { value }, during: { value = 1 }) { _ in }
        }
    }

    /// 投げる前に変えた状態も比べ、そのあとで投げ直す。
    @Test func reportsChangeBeforeThrowAndRethrows() async throws {
        var value = 0
        await withKnownIssue {
            await #expect(throws: Failure.self) {
                try await expectChanges(of: { value }, during: {
                    value = 1
                    throw Failure()
                }) { _ in }
            }
        }
    }
}
