import Foundation
import SciaCore
import SciaTesting
import Testing

/// テストで作るセッション。設定の保存先を`TestScratch`で作るので、使うスイートに`.scratch`を付ける。タイムラインはセッションを持たず、セッションを捨てるとタイムラインも止まるため、テストの間はここで持つ。
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
        let defaults = TestScratch.defaults("TestAccountSessions")
        let session = AccountSession(
            credential: credential,
            transport: transport,
            connector: connector,
            http: HTTPClient(transport: transport),
            settings: AppSettings(defaults: defaults),
            defaults: defaults,
            tuning: tuning
        )
        sessions.append(session)
        return session
    }
}
