import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct UserDisplayLoaderTests {
    private func settings() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: TestScratch.defaults("listAvatars"), userDisplayImageDirectory: TestScratch.url("listAvatars")), target: .scope(.app))
    }

    private func account() -> Account {
        Account(id: "1", username: "alice", acct: "alice@example.com", displayName: "Alice", avatar: URL(string: "https://example.com/a.gif"), avatarStatic: URL(string: "https://example.com/a.png"))
    }

    @Test func cancellingRowCancelsItsSearchRequest() async throws {
        let settings = settings()
        let account = account()
        try settings.userDisplays.save(.init(stopsAnimation: true), for: account, in: settings)
        let gate = Gate()
        let session = AccountSession.testing(transport: RoutedTransport { _ in
            try await gate.wait()
            return (200, Data(#"{"accounts":[]}"#.utf8))
        }, settings: settings)
        let tasks = session.tasks.child()
        defer { gate.open(); session.close() }
        let avatars = UserDisplayLoader(settings: settings, tasks: tasks) { try await session.resolveUserDisplayAccount(acct: $0, sharesRequests: false) }
        avatars.load(account.acct)
        try await waitUntil { gate.waiterCount == 1 }
        avatars.cancel(account.acct)
        #expect(gate.waiterCount == 0)
        gate.open()
        try await waitUntil { tasks.runningCount == 0 }
    }

    @Test func cancellingLocalRowCancelsItsDomainRequest() async throws {
        let settings = settings().forAccount("@me@web.example.com")
        let account = account()
        try settings.userDisplays.save(.init(stopsAnimation: true), for: account, in: settings)
        let fixture = try String(contentsOf: try #require(Bundle.module.url(forResource: "account", withExtension: "json", subdirectory: "Fixtures")), encoding: .utf8)
        let local = fixture.replacingOccurrences(of: "bob@remote.example", with: "alice")
        let gate = Gate()
        let session = AccountSession.testing(transport: RoutedTransport { request in
            if request.url?.path == "/api/v2/search" { return (200, Data(("{\"accounts\":[" + local + "]}").utf8)) }
            try await gate.wait()
            return (200, Data(#"{"uri":"example.com"}"#.utf8))
        }, settings: settings)
        let tasks = session.tasks.child()
        defer { gate.open(); session.close() }
        let avatars = UserDisplayLoader(settings: settings, tasks: tasks) { try await session.resolveUserDisplayAccount(acct: $0, sharesRequests: false) }
        avatars.load(account.acct)
        try await waitUntil { gate.waiterCount == 1 }
        avatars.cancel(account.acct)
        #expect(gate.waiterCount == 0)
        gate.open()
        try await waitUntil { tasks.runningCount == 0 }
        #expect(settings.userDisplayDomain == nil)
    }

    @Test func customImageNeedsNoAccountLookupAndResetLoadsOriginal() async throws {
        let settings = settings()
        let account = account()
        try settings.userDisplays.save(.init(name: "Alice"), for: account, in: settings, imageData: Data([1, 2, 3]))
        let tasks = TaskScope()
        defer { tasks.close() }
        var calls = 0
        let avatars = UserDisplayLoader(settings: settings, tasks: tasks) { _ in calls += 1; return account }
        avatars.load(account.acct)
        let custom = try #require(avatars.display(for: account.acct).avatarStatic)
        #expect(try Data(contentsOf: custom) == Data([1, 2, 3]))
        #expect(tasks.runningCount == 0)
        #expect(calls == 0)

        try settings.userDisplays.save(.init(stopsAnimation: true), for: account, in: settings)
        avatars.load(account.acct)
        avatars.load(account.acct)
        try await waitUntil { tasks.runningCount == 0 }
        #expect(avatars.display(for: account.acct).avatarStatic == account.avatarStatic)
        #expect(calls == 1)
        avatars.load(account.acct)
        #expect(tasks.runningCount == 0)
    }

    @Test func customImageWinsWhenOriginalArrivesLater() async throws {
        let settings = settings()
        let account = account()
        try settings.userDisplays.save(.init(name: "Alice"), for: account, in: settings)
        let tasks = TaskScope()
        defer { tasks.close() }
        let gate = Gate()
        let avatars = UserDisplayLoader(settings: settings, tasks: tasks) { _ in try await gate.wait(); return account }
        avatars.load(account.acct)
        try await waitUntil { gate.waiterCount == 1 }
        try settings.userDisplays.save(.init(name: "Alice"), for: account, in: settings, imageData: Data([4, 5]))
        gate.open()
        try await waitUntil { tasks.runningCount == 0 }
        let image = try #require(avatars.display(for: account.acct).avatarStatic)
        #expect(try Data(contentsOf: image) == Data([4, 5]))
    }

    @Test func failedAndCancelledLoadsCanBeRetried() async throws {
        struct Failure: Error {}
        let settings = settings()
        let account = account()
        try settings.userDisplays.save(.init(stopsAnimation: true), for: account, in: settings)
        let tasks = TaskScope()
        defer { tasks.close() }
        let gate = Gate()
        var calls = 0
        let avatars = UserDisplayLoader(settings: settings, tasks: tasks) { _ in
            calls += 1
            if calls == 1 { throw Failure() }
            if calls == 2 { try await gate.wait() }
            return account
        }
        avatars.load(account.acct)
        try await waitUntil { tasks.runningCount == 0 }
        #expect(avatars.display(for: account.acct).avatarStatic == nil)
        avatars.load(account.acct)
        try await waitUntil { gate.waiterCount == 1 }
        avatars.cancel(account.acct)
        avatars.load(account.acct)
        try await waitUntil { tasks.runningCount == 0 }
        #expect(gate.waiterCount == 0)
        #expect(avatars.display(for: account.acct).avatarStatic == account.avatarStatic)
        #expect(calls == 3)
    }
}
