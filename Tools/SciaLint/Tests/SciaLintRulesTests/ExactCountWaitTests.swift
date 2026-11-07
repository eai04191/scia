@testable import SciaLintRules
import Testing

@Suite struct ExactCountWaitTests {
    private func violations(_ statement: String, path: String = "Packages/SciaCore/Tests/SciaCoreTests/FooTests.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.exactCountWait]).count
    }

    @Test(arguments: [
        "try await waitUntil { transport.requests.count == 2 }",
        "try await waitUntil { saves(transport).count == loads + 1 && clock.sleeperCount == 1 }",
        "try await waitUntil { loads + 1 == transport.requests(to: path).count }",
        "try await waitUntil { model.items?.count == 3 }",
        "try await waitUntil { (model.items?.count ?? 0) == 3 }",
        "try await waitUntil { model.items?.count ?? 0 == 3 }",
        "try await waitUntil { await log.labels.count == 2 && clock.sleeperCount == 3 }",
        "try await waitUntil { ready && (try store.items()).count == 2 }",
        "try await waitUntil(advancing: clock, by: .seconds(1)) { requests.count == 1 }",
        "try await waitUntil(state: { describe() }) { requests.count == 1 }",
        "try await waitUntil({ requests.count == 1 })",
        // 条件を複数行に分けても見つける
        """
        try await waitUntil {
            ready
                && requests.count == 1
        }
        """,
    ])
    func flagsExactCountWaits(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test(arguments: [
        "try await waitUntil { transport.requests.count >= 2 }",
        "try await waitUntil { model.runningTaskCount == 0 && clock.sleeperCount == 1 }",
        "try await waitUntil { display.statusIDs == [\"2\", \"1\"] }",
        "try await waitUntil { groups.filter { $0.count == 2 }.isEmpty }",
        // 括弧の中の比較の結果は、件数ではなく真偽
        "try await waitUntil { (requests.count >= 2) == true }",
        "try await waitUntil(state: { \"\\(a.count == 1)\" }) { ready }",
        "#expect(transport.requests.count == 2)",
        "waitUntilClosed { requests.count == 1 }",
    ])
    func allowsOtherConditions(_ statement: String) {
        #expect(violations(statement) == 0)
    }

    @Test func checksOnlyTests() {
        let statement = "try await waitUntil { requests.count == 1 }"
        #expect(violations(statement, path: "AppTests/FooTests.swift") == 1)
        #expect(violations(statement, path: "Packages/SciaCore/Sources/SciaCore/Foo.swift") == 0)
    }
}
