import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 一覧のモデルが送った命令を記録する、偽の一覧の画面。
@MainActor
final class RecordingTimelineDisplay: TimelineDisplay, StreamingStatusDisplay {
    struct EntriesCall {
        let entries: [TimelineEntry]
        let anchorID: TimelineEntry.ID?
        let topID: TimelineEntry.ID?
        let animatesRemoval: Bool
        let base: [TimelineEntry]?
    }

    private(set) var entriesCalls: [EntriesCall] = []
    var entries: [TimelineEntry] { entriesCalls.last?.entries ?? [] }
    var statusIDs: [Status.ID] { entries.compactMap(\.status?.id) }
    private(set) var contentState = TimelineContentState.loaded
    private(set) var footerState = TimelineFooterState.idle
    private(set) var unreadCount = 0
    private(set) var isOutageNoticeShown = false
    private(set) var loadingGapIDs: Set<String> = []
    private(set) var gapFailures: [String: ErrorPresentation] = [:]
    private(set) var catchUp: CatchUpStatus?
    /// 送られた命令の数。止めたあとに何も送られないことを確かめるのに使う。
    private(set) var commandCount = 0
    var isUserInteracting = false
    var anchorID: TimelineEntry.ID?

    func setEntries(_ entries: [TimelineEntry], keeping anchorID: TimelineEntry.ID?, placingAtTop topID: TimelineEntry.ID?, keepsOffset: Bool, animatesRemoval: Bool, keepingRowContentsOf base: [TimelineEntry]?) {
        commandCount += 1
        entriesCalls.append(EntriesCall(entries: entries, anchorID: anchorID, topID: topID, animatesRemoval: animatesRemoval, base: base))
    }

    func setContentState(_ state: TimelineContentState) {
        commandCount += 1
        contentState = state
    }

    func setFooterState(_ state: TimelineFooterState) {
        commandCount += 1
        footerState = state
    }

    func setGapStates(loading ids: Set<String>, failures: [String: ErrorPresentation]) {
        commandCount += 1
        loadingGapIDs = ids
        gapFailures = failures
    }

    func setUnreadCount(_ count: Int, isLowerBound: Bool) {
        commandCount += 1
        unreadCount = count
    }

    func setOutageNotice(_ isShown: Bool) {
        commandCount += 1
        isOutageNoticeShown = isShown
    }

    func prefetchAvatars(of entries: [TimelineEntry]) {}

    func waitForAvatars(of entries: () -> [TimelineEntry], within timeout: Duration) async {}

    func currentAnchorID() -> TimelineEntry.ID? { anchorID }

    func setState(_ state: ConnectionDiagnostics.StreamingState?) {}

    func setCatchUp(_ status: CatchUpStatus) {
        catchUp = status
    }

    func setArrivalRate(_ rate: ArrivalRate) {}
}

/// リクエストのパスごとに応答を決め、受け取ったリクエストを記録するHTTPTransport。
final class RoutedTransport: HTTPTransport {
    private let respond: @Sendable (URLRequest) async throws -> (Int, Data)
    private let state = Mutex<[URLRequest]>([])

    init(_ respond: @escaping @Sendable (URLRequest) async throws -> (Int, Data)) {
        self.respond = respond
    }

    var requests: [URLRequest] { state.withLock { $0 } }

    func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path() == path }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock { $0.append(request) }
        let (statusCode, body) = try await respond(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (body, response)
    }
}

/// 一覧のモデルのテストで使う、決まった投稿と接続。
enum TimelineModelFixtures {
    static func credential() -> Credential {
        Credential(
            instance: URL(filePath: "/"),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
    }

    static func status(_ id: Int) throws -> Status {
        let avatar = try #require(URL(string: "https://example.social/avatars/bob.png"))
        return Status(
            id: String(id),
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + id)),
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar),
            content: "<p>\(id)</p>",
            spoilerText: "",
            url: nil
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// 投稿の配列を、APIの応答の本文にする。
    static func body(_ ids: [Int]) throws -> Data {
        try encoder().encode(ids.map(status))
    }

    static func body(_ statuses: [Status]) throws -> Data {
        try encoder().encode(statuses)
    }

    /// 投稿を、ストリーミングの`update`イベントのテキストにする。
    static func updateMessage(_ id: Int, stream: [String] = ["user"]) throws -> String {
        let payload = String(decoding: try encoder().encode(status(id)), as: UTF8.self)
        let envelope = try JSONSerialization.data(withJSONObject: ["stream": stream, "event": "update", "payload": payload])
        return String(decoding: envelope, as: UTF8.self)
    }

    /// 通知を、ストリーミングの`notification`イベントのテキストにする。
    static func notificationMessage(_ json: String) throws -> String {
        let envelope = try JSONSerialization.data(withJSONObject: ["stream": ["user"], "event": "notification", "payload": json])
        return String(decoding: envelope, as: UTF8.self)
    }

    /// 決まった接続につなぐハブ。再接続、ポーリング、切断の知らせは、渡した時計を進めない限り起きない。
    @MainActor
    static func hub(_ connector: ScriptedConnector = ScriptedConnector([]), clock: TestClock = TestClock()) -> StreamingHub {
        let client = StreamingClient(credential: credential(), connector: connector)
        let policy = ReconnectingStream.Policy(initialRetryDelay: .seconds(3600), maxRetryDelay: .seconds(3600), pingInterval: .seconds(3600), pingTimeout: .seconds(5))
        let live = LiveUpdates.Policy(pollingInterval: .seconds(3600), outageNoticeDelay: .seconds(3600))
        return StreamingHub(reconnectPolicy: policy, livePolicy: { live }, clock: clock) {
            try await client.open(baseURL: URL(filePath: "/"))
        }
    }
}
