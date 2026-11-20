import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct UserDisplayTests {
    @Test func customizationWarningIncludesEveryActiveSetting() throws {
        let animation = try #require(UserDisplayTexts.customizationWarning(for: .init(stopsAnimation: true)))
        var messages = Set<String>()
        for name in [nil, "Local name"] {
            for avatar in [nil, "local-avatar"] {
                let rule = UserDisplayRule(name: name, avatarFile: avatar)
                let identity = UserDisplayTexts.customizationWarning(for: rule)
                #expect((identity == nil) == rule.isEmpty)
                if let identity { messages.insert(identity) }
                var animated = rule
                animated.stopsAnimation = true
                let warning = try #require(UserDisplayTexts.customizationWarning(for: animated))
                #expect(warning.contains(animation))
                if let identity { #expect(warning.contains(identity)) }
                messages.insert(warning)
            }
        }
        #expect(messages.count == 7)
    }

    @Test func unknownHandleDomainDoesNotUseConnectionHost() {
        let settings = AppSettings(defaults: TestScratch.defaults("unknownDomain")).forAccount("@me@web.example.com")
        #expect(settings.userDisplayKey(acct: "alice") == nil)
    }

    @Test func removingUserClearsEverySettingAndPersists() throws {
        let defaults = TestScratch.defaults("removeUser")
        let store = SettingsStore(defaults: defaults, userDisplayImageDirectory: TestScratch.url("removeUser"))
        let settings = AppSettings(store: store, target: .scope(.app))
        let user = account("alice@example.com")
        try settings.userDisplays.save(.init(name: "Alice at work", stopsAnimation: true), for: user, in: settings, imageData: Data([1]))
        let image = try #require(settings.userDisplays.display(of: user, in: settings).avatar)
        settings.userDisplays.remove(forKey: "alice@example.com")
        #expect(settings.userDisplays.rules.isEmpty)
        #expect(settings.userDisplays.display(of: user, in: settings).name == user.displayName)
        #expect(!settings.userDisplays.display(of: user, in: settings).stopsAnimation)
        #expect(!FileManager.default.fileExists(atPath: image.path))
        #expect(AppSettings(defaults: defaults).userDisplays.rules.isEmpty)
    }

    private func account(_ acct: String = "alice", name: String = "Alice") -> Account {
        Account(id: "1", username: "alice", acct: acct, displayName: name, avatar: URL(string: "https://example.com/a.gif"), avatarStatic: URL(string: "https://example.com/a.png"))
    }

    @Test func rulesAreSharedAndPersistWithoutChangingAccount() throws {
        let defaults = TestScratch.defaults("UserDisplay")
        let settings = AppSettings(defaults: defaults)
        let home = settings.forAccount("@me@web.example.com")
        home.setUserDisplayDomain("example.com")
        let other = settings.forAccount("@me@other.example")
        let original = account()
        try home.userDisplays.save(.init(name: "My Alice", stopsAnimation: true), for: original, in: home)
        let display = other.userDisplays.display(of: account("ALICE@EXAMPLE.COM"), in: other)
        #expect(display.name == "My Alice")
        #expect(display.avatar(animates: true).url == original.avatarStatic)
        #expect(display.emojis.isEmpty)
        #expect(original.displayName == "Alice")
        #expect(original.avatar?.pathExtension == "gif")
        let reloaded = AppSettings(defaults: defaults).forAccount("@me@web.example.com")
        #expect(reloaded.userDisplays.display(of: original, in: reloaded).name == display.name)
        #expect(other.userDisplays.display(of: account(), in: other).name == "Alice")
        try home.userDisplays.save(.init(), for: original, in: home)
        other.userDisplays.receive(account("alice@example.com", name: "New Alice"), in: other)
        #expect(other.userDisplays.display(of: account("alice@example.com"), in: other).name == "New Alice")
        #expect(home.userDisplays.rules.isEmpty)
        #expect(home.userDisplays.display(of: original, in: home).avatar(animates: true).url == original.avatar)
    }

    @Test func imagesPersistAndAreRemovedOnlyWhenUnreferenced() throws {
        let defaults = TestScratch.defaults("UserDisplayImages")
        let directory = TestScratch.url("UserDisplayImages")
        let store = SettingsStore(defaults: defaults, userDisplayImageDirectory: directory)
        let settings = AppSettings(store: store, target: .scope(.app)).forAccount("@me@example.com")
        settings.setUserDisplayDomain("example.com")
        let data = Data([1, 2, 3])
        try settings.userDisplays.save(.init(), for: account(), in: settings, imageData: data)
        try settings.userDisplays.save(.init(name: "Other"), for: account("bob"), in: settings, imageData: data)
        let url = try #require(settings.userDisplays.display(of: account(), in: settings).avatar)
        #expect(try Data(contentsOf: url) == data)
        let reloadedStore = SettingsStore(defaults: defaults, userDisplayImageDirectory: directory)
        let reloaded = AppSettings(store: reloadedStore, target: .scope(.app)).forAccount("@me@example.com")
        #expect(reloaded.userDisplays.display(of: account(), in: reloaded).avatar == url)
        try settings.userDisplays.save(.init(stopsAnimation: true), for: account(), in: settings)
        #expect(FileManager.default.fileExists(atPath: url.path))
        settings.userDisplays.remove(forKey: "bob@example.com")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(settings.userDisplays.display(of: account(), in: settings).stopsAnimation)
        settings.userDisplays.remove(forKey: "alice@example.com")
        #expect(settings.userDisplays.rules.isEmpty)
    }

    @Test func staleImageReferenceCannotReplaceTheCurrentImage() throws {
        let store = SettingsStore(defaults: TestScratch.defaults("staleUserDisplay"), userDisplayImageDirectory: TestScratch.url("staleUserDisplay"))
        let settings = AppSettings(store: store, target: .scope(.app)).forAccount("@me@example.com")
        settings.setUserDisplayDomain("example.com")
        let user = account()
        try settings.userDisplays.save(.init(), for: user, in: settings, imageData: Data([1]))
        var stale = settings.userDisplays.display(of: user, in: settings).rule
        try settings.userDisplays.save(.init(), for: user, in: settings, imageData: Data([2]))
        let current = try #require(settings.userDisplays.display(of: user, in: settings).avatar)
        stale.name = "Name from an older editor"
        #expect(throws: CocoaError.self) { try settings.userDisplays.save(stale, for: user, in: settings) }
        #expect(settings.userDisplays.display(of: user, in: settings).avatar == current)
        #expect(try Data(contentsOf: current) == Data([2]))
    }

    @Test func localCompletionUsesTheWritingAccountsServer() throws {
        let app = AppSettings(defaults: TestScratch.defaults("completionDisplay"))
        let home = app.forAccount("@me@home.example")
        let writing = app.forAccount("@me@writing.example")
        home.setUserDisplayDomain("home.example")
        writing.setUserDisplayDomain("writing.example")
        try home.userDisplays.save(.init(name: "Home Alice"), for: account(), in: home)
        try writing.userDisplays.save(.init(name: "Writing Alice"), for: account(), in: writing)
        let candidate = LocalMention(account: account())
        #expect(home.userDisplays.display(of: candidate, in: home).name == "Home Alice")
        #expect(writing.userDisplays.display(of: candidate, in: writing).name == "Writing Alice")
        #expect(writing.userDisplays.display(of: account(), in: writing).name == "Writing Alice")
    }

    @Test func failedImageWritePreservesExistingRule() throws {
        let directory = TestScratch.url("UserDisplayFailure")
        try Data().write(to: directory)
        let store = SettingsStore(defaults: TestScratch.defaults("UserDisplayFailure"), userDisplayImageDirectory: directory)
        let settings = AppSettings(store: store, target: .scope(.app)).forAccount("@me@example.com")
        settings.setUserDisplayDomain("example.com")
        try settings.userDisplays.save(.init(name: "Existing"), for: account(), in: settings)
        #expect(throws: (any Error).self) {
            try settings.userDisplays.save(.init(name: "New"), for: account(), in: settings, imageData: Data([1]))
        }
        #expect(settings.userDisplays.display(of: account(), in: settings).name == "Existing")
    }
}
