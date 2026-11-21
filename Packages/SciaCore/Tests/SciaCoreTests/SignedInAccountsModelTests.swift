import Foundation
import Synchronization
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct SignedInAccountsModelTests {
    private final class MemoryStorage: CredentialStorage {
        private let items = Mutex<[Credential]>([])

        func loadAll() throws -> [Credential] { items.withLock { $0 } }

        func save(_ credential: Credential) throws {
            items.withLock { items in
                if let index = items.firstIndex(where: { $0.id == credential.id }) {
                    items[index] = credential
                } else {
                    items.append(credential)
                }
            }
        }

        func delete(id: Credential.ID) throws {
            items.withLock { $0.removeAll { $0.id == id } }
        }
    }

    private func credential(_ accountID: String, token: String = "token") throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: token,
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: accountID,
            username: "user\(accountID)"
        )
    }

    private func account(_ id: String) -> Account {
        Account(id: id, username: "user\(id)", acct: "user\(id)", displayName: "User \(id)", avatar: nil)
    }

    /// 401が返ったアカウントだけをログアウトされたとし、ログインし直してトークンが替わったら、読み直してログアウトされていないことにする。
    @Test func loggedOutUntilLoggedInAgain() async throws {
        let registry = try AccountRegistry(storage: MemoryStorage(), defaults: TestScratch.defaults("net.mizle.scia.tests"))
        try registry.add(try credential("1"))
        try registry.add(try credential("2", token: "old"))
        registry.select(try credential("1").id)
        let model = SignedInAccountsModel(
            registry: registry,
            currentID: registry.current?.id,
            tasks: TaskScope(),
            loadProfile: { [self] credential in
                let profile = account(credential.accountID)
                return {
                    guard credential.accessToken != "old" else { throw MastodonAPIError(statusCode: 401, message: "") }
                    return profile
                }
            },
            logIn: { credential in
                _ = try? registry.renew(Credential(
                    instance: credential.instance, accessToken: "new", clientID: credential.clientID,
                    clientSecret: credential.clientSecret, accountID: credential.accountID, username: credential.username
                ))
            }
        )

        model.reload()
        try await waitUntil { model.rows.first?.profile != nil && model.rows.last?.isLoggedOut == true }
        #expect(model.rows.map(\.isCurrent) == [true, false])
        #expect(model.rows.last?.profile == nil)

        model.logIn(try credential("2").id)
        try await waitUntil { model.rows.last?.profile != nil }
        #expect(model.rows.last?.isLoggedOut == false)
        #expect(registry.current?.accountID == "1")
    }

    /// 401でない失敗では、ログアウトされたとせず、前に読めたプロフィールを出したままにする。
    @Test func otherFailureKeepsLoadedProfile() async throws {
        let registry = try AccountRegistry(storage: MemoryStorage(), defaults: TestScratch.defaults("net.mizle.scia.tests"))
        try registry.add(try credential("1"))
        let fails = Mutex(false)
        let attempts = Mutex(0)
        let tasks = TaskScope()
        let model = SignedInAccountsModel(
            registry: registry,
            currentID: registry.current?.id,
            tasks: tasks,
            loadProfile: { [self] credential in
                let profile = account(credential.accountID)
                return {
                    attempts.withLock { $0 += 1 }
                    if fails.withLock({ $0 }) { throw MastodonAPIError(statusCode: 502, message: "") }
                    return profile
                }
            },
            logIn: { _ in }
        )

        model.reload()
        try await waitUntil { model.rows.first?.profile != nil }
        fails.withLock { $0 = true }
        model.reload()
        try await waitUntil { attempts.withLock { $0 } >= 2 }
        try await waitUntil { tasks.runningCount == 0 }

        #expect(model.rows.first?.profile?.id == "1")
        #expect(model.rows.first?.isLoggedOut == false)
    }
}
