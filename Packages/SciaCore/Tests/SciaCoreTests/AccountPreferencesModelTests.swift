import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct AccountPreferencesModelTests {
    /// アプリに戻って再読み込みしたら、その前に始めた読み込みが遅れて古い値を返しても、再読み込みした値を出す。
    /// 先の読み込みは取り消しに応じない通信として、門が開くまで待ってから古い値を返す。
    @Test func laterReloadWinsOverEarlierSlowLoad() async throws {
        let gate = Gate()
        let loads = Counter()
        let model = AccountPreferencesModel(initial: nil, load: {
            loads.increment()
            if loads.value == 1 {
                try? await gate.wait()
                return ServerPreferences(defaultVisibility: .public, defaultSensitive: false, expandsSpoilers: false, mediaDisplay: .hidesSensitive)
            }
            return ServerPreferences(defaultVisibility: .public, defaultSensitive: false, expandsSpoilers: false, mediaDisplay: .showsAll)
        }, tasks: TaskScope())

        model.reload(purpose: .action)
        try await waitUntil { gate.waiterCount == 1 }
        model.reload(purpose: .action)
        try await waitUntil { model.preferences != nil }
        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.preferences?.mediaDisplay == .showsAll)
        #expect(!model.loadFailed)
    }

    /// 読めなければ、前に読めた値を出したまま、読めなかったことを覚える。
    @Test func keepsLoadedValueWhenReloadFails() async throws {
        let initial = ServerPreferences(defaultVisibility: .public, defaultSensitive: false, expandsSpoilers: false, mediaDisplay: .hidesAll)
        let model = AccountPreferencesModel(initial: initial, load: { throw URLError(.notConnectedToInternet) }, tasks: TaskScope())

        model.reload(purpose: .action)
        try await waitUntil { model.loadFailed }

        #expect(model.preferences == initial)
    }

    /// セッションを閉じたあとに届いた値は使わない。
    @Test func ignoresLoadAfterScopeCloses() async throws {
        let gate = Gate()
        let tasks = TaskScope()
        let model = AccountPreferencesModel(initial: nil, load: {
            try? await gate.wait()
            return ServerPreferences(defaultVisibility: .public, defaultSensitive: false, expandsSpoilers: false, mediaDisplay: .showsAll)
        }, tasks: tasks)

        model.reload(purpose: .action)
        try await waitUntil { gate.waiterCount == 1 }
        tasks.close()
        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.preferences == nil)
    }
}

/// 読み込みが呼ばれた回数。読み込みはメインアクターで呼ばれる。
@MainActor
private final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
