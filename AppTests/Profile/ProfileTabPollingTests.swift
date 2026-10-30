import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

/// タブに置いたプロフィールで、前に出ている間だけ新着を読む。決まりはdocs/tabs.mdの「プロフィール」にある。
@Suite(.scratch)
@MainActor
struct ProfileTabPollingTests {
    private static let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)

    @MainActor
    private struct Opened {
        let controller: ProfileController
        let viewController: TimelineViewController
        let window: UIWindow
        let transport: StatusesTransport
        let tasks: TaskScope
        let clock: TestClock

        var interval: Duration { .seconds(viewController.tuning.value(of: TuningCatalog.shownFeedPollingInterval)) }

        /// 新着を読む待ち。一覧の相対時刻を1秒ごとに書き直す待ちも同じ時計を使うため、間隔のうちに締め切りが来るものから、それを除いて数える。
        var pollWaits: Int { clock.sleeperCount(dueWithin: interval) - clock.sleeperCount(dueWithin: .seconds(1)) }

        var statusIDs: [String] {
            viewController.displayedStatusIDs
        }

        func close() {
            tasks.close()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func open(clock: TestClock, latest: [String] = ["10"]) async throws -> Opened {
        let transport = StatusesTransport()
        transport.latest = latest
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
        let client = MastodonClient(credential: credential, transport: transport)
        let tasks = TaskScope()
        let (controller, viewController) = ProfileController.make(
            account: Self.account,
            client: client,
            relationshipCache: RelationshipCache { _ in [] },
            settings: .isolated(),
            tasks: tasks,
            onError: { _, _ in },
            onUnauthorized: {}
        )
        viewController.clock = clock
        controller.readsNewWhileShown()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: viewController)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.start()
        let opened = Opened(controller: controller, viewController: viewController, window: window, transport: transport, tasks: tasks, clock: clock)
        // 最初の一覧は、見える行のアイコンを待ってから出す。アイコンはないので、待つ上限まで時計を進める。
        try await waitUntil {
            clock.advance(by: .seconds(1))
            return opened.statusIDs == latest && opened.viewController.footerState != .loading
        }
        return opened
    }

    /// 前に出ている間は、間隔ごとに一番新しい投稿より後を読み、届いた投稿を足す。
    @Test func readsNewWhileShown() async throws {
        let clock = TestClock()
        let opened = try await open(clock: clock)
        defer { opened.close() }
        try await waitUntil { opened.pollWaits == 1 }
        let requests = opened.transport.sinceIDs.count

        opened.transport.newer = ["11"]
        clock.advance(by: opened.interval)

        try await waitUntil { opened.statusIDs == ["11", "10"] }
        #expect(opened.transport.sinceIDs.dropFirst(requests).first == "10")
        // 使う人の操作によらず送るので、レート制限で止められている間は送らない目的で送る。
        #expect(opened.transport.sincePurposes.allSatisfy { $0 == .display })
    }

    /// 投稿のなかった一覧も読み直し、最初の投稿が届いたら出す。
    @Test func readsFirstPostIntoEmptyList() async throws {
        let clock = TestClock()
        let opened = try await open(clock: clock, latest: [])
        defer { opened.close() }
        try await waitUntil { opened.pollWaits == 1 }

        opened.transport.latest = ["10"]
        clock.advance(by: opened.interval)

        try await waitUntil { opened.statusIDs == ["10"] }
    }

    /// アプリがバックグラウンドにある間は読まない。戻ったら、間隔を待たずに読む。
    @Test func stopsInBackgroundAndReadsOnReturn() async throws {
        let clock = TestClock()
        let opened = try await open(clock: clock)
        defer { opened.close() }
        try await waitUntil { opened.pollWaits == 1 }

        opened.controller.enterBackground()
        try await waitUntil { opened.pollWaits == 0 }
        let requests = opened.transport.sinceIDs.count
        opened.transport.newer = ["11"]
        clock.advance(by: opened.interval)
        #expect(opened.transport.sinceIDs.count == requests)

        opened.controller.enterForeground()

        try await waitUntil { opened.statusIDs == ["11", "10"] }
    }

    /// 見えなくなったら読まない。前に出たら、見ていなかった間の新着を読む。
    @Test func stopsWhileHiddenAndReadsWhenShown() async throws {
        let clock = TestClock()
        let opened = try await open(clock: clock)
        defer { opened.close() }
        try await waitUntil { opened.pollWaits == 1 }
        let navigation = try #require(opened.viewController.navigationController)

        navigation.pushViewController(UIViewController(), animated: false)
        opened.window.layoutIfNeeded()
        try await waitUntil { opened.pollWaits == 0 }
        let requests = opened.transport.sinceIDs.count
        opened.transport.newer = ["11"]
        clock.advance(by: opened.interval)
        #expect(opened.transport.sinceIDs.count == requests)

        navigation.popViewController(animated: false)
        opened.window.layoutIfNeeded()

        try await waitUntil { opened.statusIDs == ["11", "10"] }
    }
}

/// アカウントの投稿を返す通信。最新の読み込みには`latest`を返し、`since_id`を付けた読み込みには`newer`を返して空にする。
/// ほかの読み込みは失敗させる。プロフィールの画面は、読めなかった部分をログに残して続ける。
private final class StatusesTransport: HTTPTransport {
    private let state = Mutex<(latest: [String], newer: [String], sinceIDs: [String], sincePurposes: [RequestPurpose?])>(([], [], [], []))

    /// `since_id`も`max_id`も付けない読み込みに返す投稿。
    var latest: [String] {
        get { state.withLock { $0.latest } }
        set { state.withLock { $0.latest = newValue } }
    }

    var newer: [String] {
        get { state.withLock { $0.newer } }
        set { state.withLock { $0.newer = newValue } }
    }

    /// `since_id`を付けて読んだときの値。読んだ順。
    var sinceIDs: [String] { state.withLock { $0.sinceIDs } }

    /// `since_id`を付けて読んだときの、通信の目的。
    var sincePurposes: [RequestPurpose?] { state.withLock { $0.sincePurposes } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        guard url.path() == "/api/v1/accounts/2/statuses" else { throw URLError(.notConnectedToInternet) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ids: [String]
        if query.contains(where: { $0.name == "pinned" }) {
            ids = []
        } else if let sinceID = query.first(where: { $0.name == "since_id" })?.value {
            let purpose = RequestPurpose.current
            ids = state.withLock { state in
                state.sinceIDs.append(sinceID)
                state.sincePurposes.append(purpose)
                defer { state.newer = [] }
                return state.newer
            }
        } else if query.contains(where: { $0.name == "max_id" }) {
            ids = []
        } else {
            ids = latest
        }
        let body = Data("[\(ids.map(Self.status).joined(separator: ","))]".utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (body, response)
    }

    private static func status(_ id: String) -> String {
        #"{"id":"\#(id)","created_at":"2026-01-01T00:00:00.000Z","account":{"id":"2","username":"bob","acct":"bob","display_name":"Bob","note":"","fields":[],"emojis":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0},"content":"<p>\#(id)</p>","spoiler_text":"","sensitive":false,"visibility":"public","media_attachments":[],"mentions":[],"tags":[],"emojis":[]}"#
    }
}
