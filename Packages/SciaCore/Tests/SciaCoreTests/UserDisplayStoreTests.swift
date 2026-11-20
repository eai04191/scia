import Foundation
import Observation
import Synchronization
import SciaTesting
import Testing
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct UserDisplayStoreTests {
    private func settings() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: TestScratch.defaults("user-display-store"), userDisplayImageDirectory: TestScratch.url("user-display-images")), target: .scope(.app))
    }

    private func account(_ acct: String = "alice@example.com", name: String = "Alice", id: String = "1") -> Account {
        Account(id: id, username: "alice", acct: acct, displayName: name, avatar: URL(string: "https://example.com/a.gif"), avatarStatic: URL(string: "https://example.com/a.png"))
    }

    @Test func screensAndSessionsShareTheModelAndRestoreTheLatestOriginal() throws {
        let app = settings()
        let home = app.forAccount("@me@web.example.com")
        home.setUserDisplayDomain("example.com")
        let other = app.forAccount("@me@other.example")
        let original = account("alice")
        let profile = home.userDisplays.display(of: original, in: home)
        let timeline = other.userDisplays.display(of: account(id: "55"), in: other)
        let list = other.userDisplays.display(for: "alice@example.com", in: other)
        #expect(home.userDisplays === other.userDisplays)
        #expect(profile === timeline && timeline === list)
        try home.userDisplays.save(.init(name: "Work Alice", stopsAnimation: true), for: original, in: home, imageData: Data([1]))
        #expect(timeline.name == "Work Alice")
        #expect(list.avatarStatic?.isFileURL == true)
        #expect(!profile.avatar(animates: true).animates)
        home.userDisplays.receive(account(name: "New Alice"), in: home)
        #expect(profile.name == "Work Alice")
        home.userDisplays.remove(forKey: "alice@example.com")
        #expect(profile.name == "New Alice")
        #expect(timeline.avatar(animates: true).url == original.avatar)
        #expect(original.displayName == "Alice")
        #expect(original.avatar?.pathExtension == "gif")
    }

    @Test func localModelSurvivesLearningTheCanonicalDomain() {
        let settings = settings().forAccount("@me@web.example.com")
        let profile = settings.userDisplays.display(of: account("alice"), in: settings)
        settings.setUserDisplayDomain("example.com")
        let list = settings.userDisplays.display(for: "alice@example.com", in: settings)
        #expect(profile === list)
        settings.userDisplays.receive(account("alice", name: "New"), in: settings)
        #expect(list.name == "New")
    }

    @Test func observationTracksBothRulesAndReceivedInformation() throws {
        let settings = settings()
        let account = account()
        let display = settings.userDisplays.display(of: account, in: settings)
        let changes = Mutex(0)
        withObservationTracking { _ = display.name } onChange: { changes.withLock { $0 += 1 } }
        try settings.userDisplays.save(.init(name: "Local"), for: account, in: settings)
        #expect(changes.withLock { $0 } == 1)
        settings.userDisplays.remove(forKey: account.acct)
        withObservationTracking { _ = display.name } onChange: { changes.withLock { $0 += 1 } }
        settings.userDisplays.receive(self.account(name: "Remote update"), in: settings)
        #expect(changes.withLock { $0 } == 2)
        #expect(display.name == "Remote update")
    }

    @Test func sessionsDoNotConfuseLocalHandlesOrAccountIDs() {
        let app = settings()
        let home = app.forAccount("@me@home.example")
        let other = app.forAccount("@me@other.example")
        home.setUserDisplayDomain("home.example")
        other.setUserDisplayDomain("other.example")
        let first = home.userDisplays.display(of: account("alice"), in: home)
        let second = other.userDisplays.display(of: account("alice"), in: other)
        home.userDisplays.receive(account("alice", name: "Home"), in: home)
        #expect(first.name == "Home")
        #expect(second.name == "Alice")
        #expect(first !== second)
    }

    @Test func receivingAnAccountUpdatesTheModelThroughTheExistingCache() async throws {
        let settings = settings().forAccount("@me@example.com")
        settings.setUserDisplayDomain("example.com")
        let received = ReceivedAccounts()
        let cache = AccountCache(received: received) { _ in [] }
        let tasks = TaskScope()
        defer { tasks.close() }
        settings.userDisplays.connect(accounts: cache, settings: settings, received: received, tasks: tasks)
        let stale = account("alice")
        let display = settings.userDisplays.display(of: stale, in: settings)
        let newerOrder = received.nextOrder()
        received.remember([account("alice", name: "New")], order: newerOrder)
        try await waitUntil { display.name == "New" }
        received.remember([stale], order: newerOrder - 1)
        #expect(settings.userDisplays.display(of: stale, in: settings) === display)
        #expect(display.name == "New")
    }
    @Test func existingLocalAndCanonicalModelsStaySynchronizedAfterDomainDiscovery() throws {
        let app = settings()
        let home = app.forAccount("@me@web.example.com")
        let remote = app.forAccount("@me@other.example")
        let local = home.userDisplays.display(of: account("alice"), in: home)
        let canonical = remote.userDisplays.display(of: account(), in: remote)
        home.setUserDisplayDomain("example.com")
        home.userDisplays.receive(account("alice", name: "Updated"), in: home)
        #expect(local.name == "Updated")
        #expect(canonical.name == "Updated")
        try home.userDisplays.save(.init(name: "Custom"), for: account("alice"), in: home)
        #expect(local.name == "Custom")
        #expect(canonical.name == "Custom")
        remote.userDisplays.receive(account(name: "Again"), in: remote)
        home.userDisplays.remove(forKey: "alice@example.com")
        #expect(local.name == "Again")
        #expect(canonical.name == "Again")
    }

    @Test func localEmojiKeepsItsOriginWhenSharedAcrossServers() {
        let app = settings()
        let home = app.forAccount("@me@example.com")
        home.setUserDisplayDomain("example.com")
        let remote = app.forAccount("@me@other.example")
        let emojis = [CustomEmoji(shortcode: "cat", url: URL(string: "https://example.com/cat.gif")!, staticUrl: URL(string: "https://example.com/cat.png")!)]
        let original = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice :cat:", avatar: nil, emojis: emojis)
        let display = home.userDisplays.display(of: original, in: home)
        let shared = remote.userDisplays.display(of: account(), in: remote)
        #expect(shared === display)
        #expect(shared.emojis.first?.domain == "example.com")
        #expect(original.emojis.first?.domain == nil)
    }

    @Test func mentionHydratesAHandleOnlyPlaceholder() {
        let settings = settings()
        let placeholder = settings.userDisplays.display(for: "alice@example.com", in: settings)
        let mention = LocalMention(account: account(name: "Mention Alice"))
        let display = settings.userDisplays.display(of: mention, in: settings)
        #expect(display === placeholder)
        #expect(placeholder.name == "Mention Alice")
        #expect(placeholder.avatar == mention.avatar)
    }

    @Test func viewerUsesTheSameUpdatedAvatarAsTheHeader() {
        let settings = settings()
        let original = account()
        let display = settings.userDisplays.display(of: original, in: settings)
        let updated = Account(id: original.id, username: original.username, acct: original.acct, displayName: original.displayName, avatar: URL(string: "https://example.com/new.gif"), avatarStatic: URL(string: "https://example.com/new.png"))
        settings.userDisplays.receive(updated, in: settings)
        let attachment = display.attachment(of: .avatar, original: original)
        #expect(attachment?.url == updated.avatar)
        #expect(attachment?.previewUrl == updated.avatarStatic)
    }

    @Test func lateLookupCannotOverwriteNewerReceivedInformation() async throws {
        let settings = settings().forAccount("@me@example.com")
        let received = ReceivedAccounts()
        let cache = AccountCache(received: received) { _ in [] }
        let tasks = TaskScope()
        defer { tasks.close() }
        settings.userDisplays.connect(accounts: cache, settings: settings, received: received, tasks: tasks)
        let original = account()
        let display = settings.userDisplays.display(of: original, in: settings)
        received.remember([account(name: "New")], order: received.nextOrder())
        try await waitUntil { display.name == "New" }
        settings.userDisplays.receive(original, in: settings)
        #expect(display.name == "New")
    }

    @Test func sameAccountWindowsReadTheirOwnCache() {
        let app = settings()
        let first = app.forAccount("@me@example.com")
        let second = app.forAccount("@me@example.com")
        let firstReceived = ReceivedAccounts()
        let secondReceived = ReceivedAccounts()
        let firstCache = AccountCache(received: firstReceived) { _ in [] }
        let secondCache = AccountCache(received: secondReceived) { _ in [] }
        let tasks = TaskScope()
        defer { tasks.close() }
        let firstTasks = tasks.child()
        let secondTasks = tasks.child()
        first.userDisplays.connect(accounts: firstCache, settings: first, received: firstReceived, tasks: firstTasks)
        second.userDisplays.connect(accounts: secondCache, settings: second, received: secondReceived, tasks: secondTasks)
        firstReceived.remember([account(name: "First")], order: firstReceived.nextOrder())
        secondReceived.remember([account(name: "Second")], order: secondReceived.nextOrder())
        let display = second.userDisplays.display(of: account(), in: second)
        #expect(display.name == "Second")
        first.userDisplays.receive(account(), in: first)
        #expect(display.name == "First")
    }

    @Test func receivedInformationInvalidatesRenderingAfterModelEviction() {
        let settings = settings()
        weak let evicted = settings.userDisplays.display(of: account(), in: settings)
        for index in 0...ReceivedAccounts.limit {
            _ = settings.userDisplays.display(of: account("user\(index)@example.com", id: String(index + 2)), in: settings)
        }
        #expect(evicted == nil)
        let changes = Mutex(0)
        withObservationTracking { settings.userDisplays.observeChanges() } onChange: { changes.withLock { $0 += 1 } }
        settings.userDisplays.receive(account(name: "Updated"), in: settings)
        #expect(changes.withLock { $0 } == 1)
        #expect(settings.userDisplays.display(of: account(), in: settings).name == "Updated")
    }

}
