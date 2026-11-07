@testable import SciaLintRules
import Testing

@Suite struct TimelineStoreWithoutTesterTests {
    private func violations(_ source: String, path: String = "Packages/SciaCore/Tests/SciaCoreTests/FooTests.swift") -> Int {
        Linter.lint(source: source, path: path, rules: [.timelineStoreWithoutTester]).count
    }

    @Test(arguments: [
        "let store = TimelineStore(pageSize: 3) { _ in page }",
        "let store = TimelineStore.init(pageSize: 3) { _ in page }",
        "let store: TimelineStore = .init(pageSize: 3) { _ in page }",
        "func check(_ store: TimelineStore) {}",
        "func makeStore() -> TimelineStore { fatalError() }",
        "var stores: [TimelineStore] = []",
        "let store = SciaCore.TimelineStore(pageSize: 3) { _ in page }",
        "extension TimelineStore { func loadAll() {} }",
        // バッククォートで囲んでも同じ名前
        "let store = `TimelineStore`(pageSize: 3) { _ in page }",
        "func check(_ store: `TimelineStore`) {}",
        "func check(_ store: SciaCore.`TimelineStore`) {}",
        // 引数を複数行に分けても見つける
        """
        let store = TimelineStore(
            pageSize: 3
        ) { _ in page }
        """,
    ])
    func flagsHoldingTheStore(_ source: String) {
        #expect(violations(source) == 1)
    }

    @Test(arguments: [
        "let tester = TimelineStoreTester(pageSize: 3) { _ in page }",
        "var state = TimelineStore.State()",
        "let position = TimelineStore.DisplayPosition(anchorID: \"1\", sequence: 0)",
        "func expect(_ change: (inout TimelineStore.State) -> Void) {}",
        "let updated = TimelineStore.updatingQuoted(\"1\", in: status) { $0 }",
        "let direction: TimelineStore.GapDirection = .fromNewer",
        "// TimelineStore(pageSize: 3)",
        "let note = \"TimelineStore(pageSize: 3)\"",
    ])
    func allowsTesterNestedTypesAndStaticFunctions(_ source: String) {
        #expect(violations(source) == 0)
    }

    @Test(arguments: [
        "Packages/SciaCore/Sources/SciaCore/Timeline/FeedTimelineModel.swift",
        "Packages/SciaCore/Tests/SciaCoreTests/TimelineStoreTester.swift",
        "AppTests/Timeline/FeedTimelineControllerTests.swift",
    ])
    func checksOnlySciaCoreTestsOutsideTheTester(_ path: String) {
        #expect(violations("let store = TimelineStore(pageSize: 3) { _ in page }", path: path) == 0)
    }
}
