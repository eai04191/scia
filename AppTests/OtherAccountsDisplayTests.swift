import Foundation
import Synchronization
import SciaCore
import SciaTesting
import Testing
@testable import Scia

@Suite(.scratch, .failureState)
@MainActor
struct OtherAccountsDisplayTests {
    @Test func completionFromAnUnopenedAccountUpdatesTheSharedDisplay() async throws {
        let credential = Credential(instance: try #require(URL(string: "https://example.com")), accessToken: "token", clientID: "client", clientSecret: "secret", accountID: "me", username: "me")
        let settings = AppSettings.isolated()
        let tasks = TaskScope()
        defer { tasks.close() }
        let transport = CompletionTransport()
        let otherAccounts = OtherAccounts(current: credential, tasks: tasks, settings: settings) {
            MastodonClient(credential: $0, transport: transport, receivedAccounts: $1)
        }
        let account = OtherAccount(credential: credential, operations: .init(client: MastodonClient(credential: credential, transport: transport)), tasks: tasks)
        let context = otherAccounts.displaySettings(for: account)
        let client = otherAccounts.client(for: account)
        let found = try await RequestPurpose.$current.withValue(.display) { try await client.searchAccountsForCompletion("alice", limit: 5) }
        let first = try #require(found.first)
        let display = context.userDisplays.display(of: first, in: context)
        #expect(display.name == "First")
        _ = try await RequestPurpose.$current.withValue(.display) { try await client.searchAccountsForCompletion("alice", limit: 5) }
        try await waitUntil { display.name == "Updated" }
        #expect(context.userDisplays === settings.userDisplays)
        #expect(display.avatar?.lastPathComponent == "Updated.png")
    }
}

private final class CompletionTransport: HTTPTransport {
    private let calls = Mutex(0)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let count = calls.withLock { $0 += 1; return $0 }
        let name = count == 1 ? "First" : "Updated"
        let account = Account(id: "alice", username: "alice", acct: "alice@example.com", displayName: name, avatar: URL(string: "https://example.com/\(name).png"))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode([account])
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}
