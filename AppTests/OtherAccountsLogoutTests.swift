import Foundation
import Synchronization
import SciaCore
import SciaTesting
import Testing
@testable import Scia

@Suite(.scratch, .failureState)
@MainActor
struct OtherAccountsLogoutTests {
    /// 投稿欄で投稿先を替えている途中にほかの窓でログアウトしても、メニューを開き直すまで古い一覧から見つけてしまうと、ログアウトしたアカウントで送れてしまう。
    @Test func loggedOutAccountIsNotFoundBeforeTheListIsReadAgain() throws {
        let me = try Self.credential("me")
        let other = try Self.credential("other")
        let registry = try AccountRegistry(storage: MemoryStorage([me, other]), defaults: TestScratch.defaults("net.mizle.scia.tests"))
        let tasks = TaskScope()
        defer { tasks.close() }
        let otherAccounts = OtherAccounts(current: me, tasks: tasks, settings: AppSettings.isolated(), registry: { registry }) {
            MastodonClient(credential: $0, transport: NoRequestTransport(), receivedAccounts: $1)
        }
        _ = otherAccounts.list(loadsProfiles: false)
        #expect(otherAccounts.account(id: other.id) != nil)

        try registry.remove(other.id)

        #expect(otherAccounts.account(id: other.id) == nil)
    }

    /// ログアウトしたアカウントのシートを開いたままにしていても、そのアカウントのトークンで送らない。ログアウトはサーバーのトークンを取り消さないため、送れば通ってしまう。
    @Test func clientOfLoggedOutAccountSendsNothing() async throws {
        let me = try Self.credential("me")
        let other = try Self.credential("other")
        let registry = try AccountRegistry(storage: MemoryStorage([me, other]), defaults: TestScratch.defaults("net.mizle.scia.tests"))
        let tasks = TaskScope()
        defer { tasks.close() }
        let transport = RecordingTransport()
        let otherAccounts = OtherAccounts(current: me, tasks: tasks, settings: AppSettings.isolated(), registry: { registry }) {
            MastodonClient(credential: $0, transport: transport, receivedAccounts: $1)
        }
        let account = try #require(otherAccounts.list(loadsProfiles: false).first)
        let client = otherAccounts.latestClient(for: account)

        try registry.remove(other.id)

        let error = await #expect(throws: (any Error).self) { try await RequestPurpose.$current.withValue(.action) { try await client().ownAccount() } }
        #expect(transport.requests.isEmpty)
        // 端末から消したアカウントはログインし直しても戻さないので、ログインし直すボタンを付けない。
        let presentation = ErrorPresentation(try #require(error))
        #expect(presentation.loggedOutAccount == nil)
    }

    private static func credential(_ username: String) throws -> Credential {
        Credential(instance: try #require(URL(string: "https://\(username).example")), accessToken: "token", clientID: "client", clientSecret: "secret", accountID: username, username: username)
    }
}

private final class MemoryStorage: CredentialStorage {
    private let items: Mutex<[Credential]>

    init(_ credentials: [Credential]) {
        items = Mutex(credentials)
    }

    func loadAll() throws -> [Credential] { items.withLock { $0 } }

    func save(_ credential: Credential) throws {
        items.withLock { items in
            items.removeAll { $0.id == credential.id }
            items.append(credential)
        }
    }

    func delete(id: Credential.ID) throws {
        items.withLock { $0.removeAll { $0.id == id } }
    }
}

private struct NoRequestTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class RecordingTransport: HTTPTransport {
    private let recorded = Mutex<[URLRequest]>([])

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        throw URLError(.notConnectedToInternet)
    }
}
