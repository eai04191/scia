@testable import SciaLintRules
import Testing

@Suite struct TaskWithoutRequestPurposeTests {
    private func violations(_ statement: String, path: String = "App/Sources/Foo.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.taskWithoutRequestPurpose]).count
    }

    @Test(arguments: [
        "Task { await load() }",
        "Task(priority: .high) { await load() }",
        "Task<Void, Never> { await load() }",
        "Task.immediate { await load() }",
        "Task.detached { await load() }",
        "Task.detached(.action) { await load() }",
        "Task<Void, Never>.detached { await load() }",
        "Task.init { await load() }",
        "Task.immediateDetached { await load() }",
        "view.task { await load() }",
        "view.task(id: id) { await load() }",
        "_Concurrency.Task { await load() }",
        "_Concurrency.Task<Void, Never>.detached { await load() }",
        // 関数として取り出したところで止める
        "let start = Task<Void, Never>.detached",
        // 引数を複数行に分けても見つける
        """
        Task(
            priority: .high
        ) {
            await load()
        }
        """,
    ])
    func flagsTasksWithoutPurpose(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test(arguments: [
        "Task(.action) { await load() }",
        "Task(.withoutRequests) { await load() }",
        "Task(.action(.refresh), priority: .high) { await load() }",
        "Task<Void, Never>(.display) { await load() }",
        "Task.immediate(.withoutRequests) { await load() }",
        "view.task(.action) { await load() }",
        "view.task(.withoutRequests, id: id) { await load() }",
        "try await Task.sleep(for: .seconds(1))",
        "await Task.yield()",
        "if Task.isCancelled { return }",
        "let task: Task<Void, Never>? = nil",
        // 引数を複数行に分けても、目的を名乗っていれば止めない
        """
        Task(
            .action
        ) {
            await load()
        }
        """,
    ])
    func allowsTasksWithPurpose(_ statement: String) {
        #expect(violations(statement) == 0)
    }

    @Test func skipsDebugAndCore() {
        #expect(violations("Task { }", path: "App/Sources/Debug/Foo.swift") == 0)
        #expect(violations("Task { }", path: "Packages/SciaCore/Sources/SciaCore/Foo.swift") == 0)
    }
}

@Suite struct SessionTaskOutsideScopeTests {
    private func violations(_ statement: String, path: String = "App/Sources/SessionController.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.sessionTaskOutsideScope]).count
    }

    @Test(arguments: [
        "Task { await load() }",
        "Task(.action) { await load() }",
        "Task(.withoutRequests, priority: .high) { await load() }",
        "Task.detached { await load() }",
        "Task.immediate(.action) { await load() }",
        "Task<Void, Never> { await load() }",
        "Task(.action) { @MainActor in await load() }",
        "_Concurrency.Task { await load() }",
    ])
    func flagsTasksOutsideTheScope(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test(arguments: [
        "Task(.withoutRequests) { await load() }",
        "Task { @MainActor in self.update() }",
        "Task { @MainActor [weak self] in self?.update() }",
        "scope.run(.action) { await load() }",
        "view.task { await load() }",
        "try await Task.sleep(for: .seconds(1))",
    ])
    func allowsScopedOrHoppingTasks(_ statement: String) {
        #expect(violations(statement) == 0)
    }

    @Test func checksOnlySessionOwnedFiles() {
        #expect(violations("Task { }", path: "App/Sources/Timeline/FeedTimelineController.swift") == 1)
        #expect(violations("Task { }", path: "Packages/SciaCore/Sources/SciaCore/Thread/ThreadModel.swift") == 1)
        #expect(violations("Task { }", path: "App/Sources/Foo.swift") == 0)
    }
}
