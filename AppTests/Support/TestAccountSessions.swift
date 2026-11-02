import Foundation
import SciaCore
import Testing

/// テストで作るセッション。一覧はセッションを持たず、セッションを捨てると一覧も止まるため、テストの間はここで持つ。
@MainActor
final class TestAccountSessions {
    private(set) var sessions: [AccountSession] = []

    func make(
        transport: some HTTPTransport,
        connector: some WebSocketConnector = MessageQueueConnector(),
        tuning: TuningStore = TuningStore(defaults: nil)
    ) throws -> AccountSession {
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
        let session = AccountSession(credential: credential, transport: transport, connector: connector, tuning: tuning)
        sessions.append(session)
        return session
    }
}
