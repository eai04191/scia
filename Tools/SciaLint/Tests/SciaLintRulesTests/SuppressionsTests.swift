@testable import SciaLintRules
import Testing

@Suite struct SuppressionsTests {
    private let path = "App/Sources/SessionController.swift"

    @Test func disablesTheNextLine() {
        let source = """
        // scialint:disable:next session_task_outside_scope
        Task {}
        Task {}
        """
        #expect(Linter.lint(source: source, path: path, rules: [.sessionTaskOutsideScope]).map(\.line) == [3])
    }

    @Test func disablesARegion() {
        let source = """
        // scialint:disable session_task_outside_scope
        Task {}
        // scialint:enable session_task_outside_scope
        Task {}
        """
        #expect(Linter.lint(source: source, path: path, rules: [.sessionTaskOutsideScope]).map(\.line) == [4])
    }

    @Test func disablesTheSameLine() {
        let source = """
        Task {} // scialint:disable:this session_task_outside_scope
        """
        #expect(Linter.lint(source: source, path: path, rules: [.sessionTaskOutsideScope]).isEmpty)
    }

    @Test func reportsUnknownRules() {
        let source = """
        // scialint:disable:next session_task_outside_scop
        Task {}
        """
        #expect(Linter.lint(source: source, path: path, rules: [.sessionTaskOutsideScope]).map(\.rule) == ["scialint", "session_task_outside_scope"])
    }
}
