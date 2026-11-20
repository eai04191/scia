import Foundation
import Synchronization
import Testing

final class TestDiagnostics: Sendable {
    @TaskLocal static var current: TestDiagnostics?

    private struct State {
        var nextID = 0
        var resources: [Int: String] = [:]
        var events: [String] = []
        var omitted = 0
        var captured = false
        var scratch: [TestScratch.Registry] = []
    }

    private let state = Mutex(State())
    private let emit: @Sendable (Data, String) -> Void

    init(emit: @escaping @Sendable (Data, String) -> Void = { Attachment.record($0, named: $1) }) {
        self.emit = emit
    }

    func register(_ label: String) -> Int {
        state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.resources[id] = label
            return id
        }
    }

    func note(_ id: Int, _ value: String) {
        state.withLock { state in
            state.resources[id] = value
            state.events.append("[\(id)] \(value)")
            if state.events.count > 128 {
                state.events.removeFirst()
                state.omitted += 1
            }
        }
    }

    var history: String {
        state.withLock { state in
            let resources = state.resources.sorted { $0.key < $1.key }.map { "[\($0.key)] \($0.value)" }
            return "状態\n" + resources.joined(separator: "\n") + "\n履歴（先頭\(state.omitted)件省略）\n" + state.events.joined(separator: "\n")
        }
    }

    func capture(_ issue: Issue) {
        guard issue.isFailure else { return }
        let registries = state.withLock { state -> [TestScratch.Registry]? in
            guard !state.captured else { return nil }
            state.captured = true
            return state.scratch
        }
        guard let registries else { return }
        let report = "\(issue)\n\(Self.environmentAndStack)\n\(history)"
        emit(Data(report.utf8), "failure-diagnostics.txt")
        for registry in registries { registry.captureFiles(emit: emit) }
    }

    static var environmentAndStack: String {
        "テスト: \(Test.current?.id.description ?? "不明")\nOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nCPU: \(ProcessInfo.processInfo.activeProcessorCount)\n失敗を記録したスレッドのスタック:\n\(Thread.callStackSymbols.joined(separator: "\n"))"
    }

    func withScope(for test: Test, testCase: Test.Case?, scratch: TestScratch.Registry? = nil, performing body: @Sendable () async throws -> Void) async throws {
        if let scratch { state.withLock { $0.scratch.append(scratch) } }
        defer {
            if let scratch { state.withLock { $0.scratch.removeAll { $0 === scratch } } }
        }
        let handler = IssueHandlingTrait.compactMapIssues { issue in
            self.capture(issue)
            return issue
        }
        try await Self.$current.withValue(self) {
            try await handler.provideScope(for: test, testCase: testCase) {
                try await body()
            }
        }
    }
}

struct DiagnosticResource: Sendable {
    private let diagnostics = TestDiagnostics.current
    private let id: Int?
    private let label: String

    init(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        self.label = "\(label) \(sourceLocation)"
        id = diagnostics?.register(self.label)
    }

    func note(_ value: String) {
        if let id { diagnostics?.note(id, "\(label): \(value)") }
    }
}
