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
        let settings = AppSettings.isolated()
        let shared = SignedInAccounts(settings: settings, registry: { registry }) {
            MastodonClient(credential: $0, transport: NoRequestTransport(), receivedAccounts: $1)
        }
        let otherAccounts = OtherAccounts(current: me, tasks: tasks, settings: settings, shared: shared, registry: { registry })
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
        let settings = AppSettings.isolated()
        let shared = SignedInAccounts(settings: settings, registry: { registry }) {
            MastodonClient(credential: $0, transport: transport, receivedAccounts: $1)
        }
        let otherAccounts = OtherAccounts(current: me, tasks: tasks, settings: settings, shared: shared, registry: { registry })
        let account = try #require(otherAccounts.list(loadsProfiles: false).first)
        let client = otherAccounts.latestClient(for: account)

        try registry.remove(other.id)

        let error = await #expect(throws: (any Error).self) { try await RequestPurpose.$current.withValue(.action) { try await client().ownAccount() } }
        #expect(transport.requests.isEmpty)
        // 端末から消したアカウントはログインし直しても戻さないので、ログインし直すボタンを付けない。
        let presentation = ErrorPresentation(try #require(error))
        #expect(presentation.loggedOutAccount == nil)
    }

    /// ウィンドウを2つ開いても、同じアカウントの見つけた投稿やクライアントを2つずつ持たない。ウィンドウのアカウントを切り替えて画面一式を作り直しても、作り直さない。
    @Test func windowsShareTheSameAccount() throws {
        let me = try Self.credential("me")
        let other = try Self.credential("other")
        let registry = try AccountRegistry(storage: MemoryStorage([me, other]), defaults: TestScratch.defaults("net.mizle.scia.tests"))
        let settings = AppSettings.isolated()
        let shared = SignedInAccounts(settings: settings, registry: { registry }) {
            MastodonClient(credential: $0, transport: NoRequestTransport(), receivedAccounts: $1)
        }
        let firstTasks = TaskScope()
        let secondTasks = TaskScope()
        defer {
            firstTasks.close()
            secondTasks.close()
        }
        let first = OtherAccounts(current: me, tasks: firstTasks, settings: settings, shared: shared, registry: { registry })
        let second = OtherAccounts(current: me, tasks: secondTasks, settings: settings, shared: shared, registry: { registry })

        let account = try #require(first.list(loadsProfiles: false).first)
        firstTasks.close()
        let reopened = OtherAccounts(current: me, tasks: TaskScope(), settings: settings, shared: shared, registry: { registry })

        #expect(second.list(loadsProfiles: false).first === account)
        #expect(reopened.account(id: other.id) === account)
    }

    /// 2つ目のウィンドウで同じアカウントを使い始めても、1つ目のウィンドウで読んだ人の表示が、そのあとに受け取った名前に変わり続ける。
    @Test func displaysKeepUpdatingAfterAnotherWindowUsesTheAccount() async throws {
        let me = try Self.credential("me")
        let other = try Self.credential("other")
        let registry = try AccountRegistry(storage: MemoryStorage([me, other]), defaults: TestScratch.defaults("net.mizle.scia.tests"))
        let settings = AppSettings.isolated()
        let transport = RenamingTransport()
        let shared = SignedInAccounts(settings: settings, registry: { registry }) {
            MastodonClient(credential: $0, transport: transport, receivedAccounts: $1)
        }
        let tasks = TaskScope()
        defer { tasks.close() }
        let first = OtherAccounts(current: me, tasks: tasks, settings: settings, shared: shared, registry: { registry })
        let account = try #require(first.list(loadsProfiles: false).first)
        let context = first.displaySettings(for: account)
        let client = first.client(for: account)
        let alice = try await RequestPurpose.$current.withValue(.display) { try await client.account("alice") }
        let display = context.userDisplays.display(of: alice, in: context)
        #expect(display.name == "Alice 1")

        let second = OtherAccounts(current: me, tasks: tasks, settings: settings, shared: shared, registry: { registry })
        let secondClient = second.client(for: try #require(second.list(loadsProfiles: false).first))
        _ = try await RequestPurpose.$current.withValue(.display) { try await secondClient.account("alice") }

        try await waitUntil { display.name == "Alice 2" }
    }

    /// ログアウトしたアカウントの部品は、ウィンドウを開いたままでも閉じ、そのアカウントで始めた処理を止める。
    @Test func loggingOutClosesTheSharedAccount() async throws {
        let me = try Self.credential("me")
        let other = try Self.credential("other")
        let registry = try AccountRegistry(storage: MemoryStorage([me, other]), defaults: TestScratch.defaults("net.mizle.scia.tests"))
        let shared = SignedInAccounts(settings: AppSettings.isolated(), registry: { registry }) {
            MastodonClient(credential: $0, transport: NoRequestTransport(), receivedAccounts: $1)
        }
        let signedIn = shared.account(other)

        try registry.remove(other.id)

        try await waitUntil { signedIn.tasks.isClosed }
    }

    /// ハッシュタグの状態はウィンドウをまたいで共有するが、済んだことは操作したウィンドウにだけ出す。
    @Test func hashtagChangeIsReportedToTheWindowThatMadeIt() async throws {
        let me = try Self.credential("me")
        let other = try Self.credential("other")
        let registry = try AccountRegistry(storage: MemoryStorage([me, other]), defaults: TestScratch.defaults("net.mizle.scia.tests"))
        let settings = AppSettings.isolated()
        let shared = SignedInAccounts(settings: settings, registry: { registry }) {
            MastodonClient(credential: $0, transport: TagTransport(), receivedAccounts: $1)
        }
        let tasks = TaskScope()
        defer { tasks.close() }
        let first = OtherAccounts(current: me, tasks: tasks, settings: settings, shared: shared, registry: { registry })
        let second = OtherAccounts(current: me, tasks: tasks, settings: settings, shared: shared, registry: { registry })
        let firstDone = Recorded()
        let secondDone = Recorded()
        first.onHashtagDone = { _, title in firstDone.titles.append(title) }
        second.onHashtagDone = { _, title in secondDone.titles.append(title) }
        let account = try #require(first.list(loadsProfiles: false).first)
        _ = second.list(loadsProfiles: false)

        first.hashtagActions(for: account).follow?.turnOn("swift")

        try await waitUntil { firstDone.titles.count >= 1 }
        #expect(firstDone.titles == [HashtagChangeTexts.followed("swift")])
        #expect(secondDone.titles.isEmpty)
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

/// 同じ人を読むたびに、名前の番号を1つずつ進めて返す。
private final class RenamingTransport: HTTPTransport {
    private let calls = Mutex(0)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let count = calls.withLock { $0 += 1; return $0 }
        let account = Account(id: "alice", username: "alice", acct: "alice@example.com", displayName: "Alice \(count)", avatar: nil)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (try encoder.encode(account), response)
    }
}

/// どの要求にも、ハッシュタグ1つを返す。
private struct TagTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(#"{"name":"swift","url":"https://other.example/tags/swift","history":[]}"#.utf8), response)
    }
}

@MainActor
private final class Recorded {
    var titles: [String] = []
}
