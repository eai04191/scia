import CoreGraphics
import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// ログアウトの後始末で、アカウントのために残したものを消し忘れないことを確かめる。
@Suite(.scratch)
@MainActor
struct AccountLogoutTests {
    private final class MemoryStorage: CredentialStorage {
        private let items = Mutex<[Credential]>([])
        let failsToDelete: Bool

        init(failsToDelete: Bool = false) {
            self.failsToDelete = failsToDelete
        }

        func loadAll() throws -> [Credential] { items.withLock { $0 } }

        func save(_ credential: Credential) throws {
            items.withLock { $0.append(credential) }
        }

        func delete(id: Credential.ID) throws {
            if failsToDelete { throw CocoaError(.fileWriteNoPermission) }
            items.withLock { $0.removeAll { $0.id == id } }
        }
    }

    private let root = TestScratch.url("AccountLogoutTests")
    private let defaults = TestScratch.defaults("AccountLogoutTests")
    private let mediaURL = URL(string: "https://files.example.social/original.png")!

    private func credential(_ username: String, accountID: String, host: String = "example.social") throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://\(host)")),
            accessToken: "token-\(username)",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: accountID,
            username: username
        )
    }

    private func makeStores(settings: AppSettings) -> ImageStores<CGImage> {
        let http = HTTPClient(transport: StubTransport([]), retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock(), now: { Date(timeIntervalSince1970: 0) })
        return ImageStores(
            http: http,
            tuning: TuningStore(defaults: nil),
            network: NetworkConditionsMonitor(monitor: nil),
            settings: settings,
            maker: PlatformImageMaker<CGImage>(still: { $0 }, animated: { _, _ in nil }),
            clock: TestClock(),
            mediaFiles: MediaFileCache(directory: root.appending(path: "files"), sharingDirectory: root.appending(path: "sharing")) { Date(timeIntervalSince1970: 0) },
            mediaPrefetchFiles: MediaFileCache(directory: root.appending(path: "prefetch"), sharingDirectory: root.appending(path: "prefetch-sharing")) { Date(timeIntervalSince1970: 0) },
            customEmojis: CustomEmojiCaches(directory: root.appending(path: "emojis"), clock: TestClock()),
            emojiImageFiles: MediaFileCache(directory: root.appending(path: "emoji-images"), sharingDirectory: root.appending(path: "emoji-sharing"))
        )
    }

    /// 見たメディアを2つのキャッシュに、カスタム絵文字のリストをサーバーごとのキャッシュに置く。
    private func fill(_ stores: ImageStores<CGImage>, emojisOf accounts: [Credential]) async throws {
        for files in [stores.mediaFiles, stores.mediaPrefetchFiles] {
            _ = try await files.store(Data([1]), named: "original.png", for: mediaURL, generation: files.generation)
        }
        for account in accounts {
            let cache = stores.customEmojis.cache(for: account.instance)
            let url = account.instance.appending(path: "emoji.png")
            cache.remember([ServerEmoji(shortcode: "blobcat", url: url, staticUrl: url, aspectRatio: nil)], loadStartedAt: cache.generation)
        }
    }

    @Test func removesAccountSettingsMediaCachesAndServerEmojis() async throws {
        let settings = AppSettings(defaults: defaults)
        let registry = try AccountRegistry(storage: MemoryStorage(), defaults: defaults)
        let alice = try credential("alice", accountID: "1")
        let bob = try credential("bob", accountID: "2", host: "other.example")
        try registry.add(bob)
        try registry.add(alice)
        settings.setSwitchTabItem(.notifications, for: alice.handle)
        settings.setSwitchTabItem(.notifications, for: bob.handle)
        let stores = makeStores(settings: settings)
        try await fill(stores, emojisOf: [alice, bob])

        try await AccountLogout.logOut(alice, from: registry, defaults: defaults, settings: settings, images: stores).value

        #expect(registry.accounts == [bob])
        #expect(registry.current == bob)
        #expect(AppSettings(defaults: defaults).switchTabItem(for: alice.handle) == nil)
        #expect(AppSettings(defaults: defaults).switchTabItem(for: bob.handle) == .notifications)
        #expect(await !stores.mediaFiles.contains(mediaURL))
        #expect(await !stores.mediaPrefetchFiles.contains(mediaURL))
        #expect(stores.customEmojis.cache(for: alice.instance).snapshot.emojis == nil)
        #expect(stores.customEmojis.cache(for: bob.instance).snapshot.emojis?.map(\.shortcode) == ["blobcat"])
    }

    /// カスタム絵文字のリストはサーバーのものなので、同じサーバーのアカウントが残っていれば残す。
    @Test func keepsServerEmojisWhileAnotherAccountOfTheServerRemains() async throws {
        let settings = AppSettings(defaults: defaults)
        let registry = try AccountRegistry(storage: MemoryStorage(), defaults: defaults)
        let alice = try credential("alice", accountID: "1")
        let carol = try credential("carol", accountID: "3")
        try registry.add(carol)
        try registry.add(alice)
        let stores = makeStores(settings: settings)
        try await fill(stores, emojisOf: [alice])

        try await AccountLogout.logOut(alice, from: registry, defaults: defaults, settings: settings, images: stores).value

        #expect(stores.customEmojis.cache(for: carol.instance).snapshot.emojis?.map(\.shortcode) == ["blobcat"])
    }

    /// 端末から消せなかったアカウントは残っているので、そのアカウントのために残したものも消さない。
    @Test func removesNothingWhenCredentialCannotBeDeleted() async throws {
        let settings = AppSettings(defaults: defaults)
        let registry = try AccountRegistry(storage: MemoryStorage(failsToDelete: true), defaults: defaults)
        let alice = try credential("alice", accountID: "1")
        try registry.add(alice)
        settings.setSwitchTabItem(.notifications, for: alice.handle)
        let stores = makeStores(settings: settings)
        try await fill(stores, emojisOf: [alice])

        #expect(throws: CocoaError.self) {
            try AccountLogout.logOut(alice, from: registry, defaults: defaults, settings: settings, images: stores)
        }

        #expect(registry.accounts == [alice])
        #expect(AppSettings(defaults: defaults).switchTabItem(for: alice.handle) == .notifications)
        #expect(await stores.mediaFiles.contains(mediaURL))
        #expect(stores.customEmojis.cache(for: alice.instance).snapshot.emojis?.map(\.shortcode) == ["blobcat"])
    }
}
