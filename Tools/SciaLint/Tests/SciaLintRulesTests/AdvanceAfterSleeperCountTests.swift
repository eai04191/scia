@testable import SciaLintRules
import Testing

@Suite struct AdvanceAfterSleeperCountTests {
    private func violations(_ source: String, path: String = "Packages/SciaCore/Tests/SciaCoreTests/FooTests.swift") -> Int {
        Linter.lint(source: "func f() async throws {\n\(source)\n}", path: path, rules: [.advanceAfterSleeperCount]).count
    }

    @Test(arguments: [
        """
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        """,
        """
        try await waitUntil { clock.sleeperCount(dueWithin: duration) >= 1 }
        clock.advance(by: duration)
        """,
        """
        try await waitUntil { store.hasFailed && clock.sleeperCount > 0 }
        clock.advance(by: .seconds(1))
        """,
        // #expectの中のawaitは、待ちが揃うのを待たない
        """
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(await log.count == 1)
        clock.advance(by: .seconds(1))
        """,
        // 別のTaskの中のawaitでは、呼び出し元は待たない
        """
        try await waitUntil { clock.sleeperCount == 1 }
        let task = Task { try await gate.wait() }
        clock.advance(by: .seconds(1))
        """,
        // 間に待たない文があっても見つける
        """
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(count == 0)
        clock.advance(by: .seconds(1))
        """,
    ])
    func flagsAdvanceAfterCounting(_ source: String) {
        #expect(violations(source) == 1)
    }

    @Test(arguments: [
        "try await clock.advance(afterSleeping: .seconds(1))",
        "try await clock.advance(by: .milliseconds(999), afterSleeping: .seconds(1))",
        "clock.advance(by: .seconds(1))",
        // 長さで指して数えれば、別の待ちを数えない
        """
        try await waitUntil { store.hasFailed && clock.sleeperCount(remaining: .seconds(1)) >= 1 }
        clock.advance(by: .seconds(1))
        """,
        // 別の待ちを挟めば、その待ちが揃えた状態で進める
        """
        try await waitUntil { clock.sleeperCount == 1 }
        try await waitUntil { gate.waiterCount == 1 }
        clock.advance(by: .seconds(1))
        """,
        // 別の関数の待ちとadvanceは結び付けない
        """
        func first() async throws {
            try await waitUntil { clock.sleeperCount == 1 }
        }
        func second() {
            clock.advance(by: .seconds(1))
        }
        """,
        // 閉包の中のadvanceは、続けて走るとは限らない
        """
        try await waitUntil { clock.sleeperCount == 1 }
        let advance = { clock.advance(by: .seconds(1)) }
        """,
        // 数を確かめるだけなら止めない
        "try await waitUntil { clock.sleeperCount == 0 }",
        // 別の処理の待ちと、時計を進める別の関数
        """
        try await waitUntil { requests.count >= 1 }
        clock.advance(by: .seconds(1))
        """,
        """
        try await waitUntil { clock.sleeperCount == 1 }
        page.advance(to: 1)
        """,
    ])
    func allowsOtherForms(_ source: String) {
        #expect(violations(source) == 0)
    }

    @Test func onlyAppliesToTests() {
        #expect(violations("try await waitUntil { clock.sleeperCount == 1 }\nclock.advance(by: .seconds(1))", path: "App/Sources/Foo.swift") == 0)
    }

    @Test func flagsAppTests() {
        #expect(violations("try await waitUntil { clock.sleeperCount == 1 }\nclock.advance(by: .seconds(1))", path: "AppTests/Foo/FooTests.swift") == 1)
    }
}
