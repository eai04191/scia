import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

/// プロフィールのタイムラインは、ヘッダーの棚（固定された投稿、注目のハッシュタグ、紹介している人）を待って出す。
/// 棚が届かなくても、開いてから`ResponseWait.limit`がたったら、届いている投稿で出す。
@Suite(.scratch, .failureState)
@MainActor
struct ProfileShelvesWaitTests {
    private static let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)

    @MainActor
    private struct Opened {
        let controller: ProfileController
        let viewController: TimelineViewController
        let window: UIWindow
        let transport: ShelvesTransport
        let tasks: TaskScope
        let clock: TestClock

        /// 棚を待つのをやめるまでの待ち。タイムラインの相対時刻を書き直す待ちとアイコンの待ちも同じ時計を使うため、締め切りがちょうどこの長さのものだけを数える。
        var shelvesWaits: Int { clock.sleeperCount(remaining: ResponseWait.limit) }

        func close() {
            tasks.close()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func open(clock: TestClock) throws -> Opened {
        let transport = ShelvesTransport()
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
            onError: { _, _ in }
        )
        viewController.clock = clock
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: viewController)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.start()
        return Opened(controller: controller, viewController: viewController, window: window, transport: transport, tasks: tasks, clock: clock)
    }

    /// 棚が届かない間は、投稿が届いていてもタイムラインを出さない。待つのをやめる長さがたったら、届いている投稿で出す。
    @Test func revealsListWithoutShelvesAfterLimit() async throws {
        let clock = TestClock()
        let opened = try open(clock: clock)
        defer { opened.close() }
        try await waitUntil { opened.transport.shelves.waiterCount >= 3 && opened.transport.listRequestCount >= 1 && opened.shelvesWaits == 1 }
        #expect(opened.viewController.displayedStatusIDs.isEmpty)

        try await clock.advance(afterSleeping: ResponseWait.limit)

        // タイムラインを最初に出すときは、見える行のアイコンを待ってから出す。アイコンはないので、待つ上限まで時計を進める。
        try await waitUntil {
            clock.advance(by: .seconds(1))
            return opened.viewController.displayedStatusIDs == ["10"]
        }
    }

    /// 棚が先に届いたら、待つのをやめる長さを待たずにタイムラインを出し、待つ処理を残さない。
    @Test func revealsListWhenShelvesArriveBeforeLimit() async throws {
        let clock = TestClock()
        let opened = try open(clock: clock)
        defer { opened.close() }
        try await waitUntil { opened.transport.shelves.waiterCount >= 3 && opened.shelvesWaits == 1 }

        opened.transport.shelves.open()

        try await waitUntil {
            clock.advance(by: .milliseconds(100))
            return opened.viewController.displayedStatusIDs == ["10"]
        }
        try await waitUntil { opened.clock.sleeperCount(dueWithin: ResponseWait.limit) == opened.clock.sleeperCount(dueWithin: .seconds(1)) }
    }
}

/// 投稿はすぐ返し、棚（固定された投稿、注目のハッシュタグ、紹介している人）は門を開くまで返さない。
private final class ShelvesTransport: HTTPTransport {
    let shelves = Gate()
    private let listRequests = Mutex(0)

    var listRequestCount: Int { listRequests.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isPinned = query.contains { $0.name == "pinned" }
        let body: String
        switch url.path() {
        case "/api/v1/accounts/2/featured_tags", "/api/v1/accounts/2/endorsements":
            try await waitForShelves()
            body = "[]"
        case "/api/v1/accounts/2/statuses" where isPinned:
            try await waitForShelves()
            body = "[]"
        case "/api/v1/accounts/2/statuses":
            listRequests.withLock { $0 += 1 }
            body = query.contains { $0.name == "max_id" || $0.name == "since_id" } ? "[]" : "[\(Self.status("10"))]"
        default:
            throw URLError(.notConnectedToInternet)
        }
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }

    private func waitForShelves() async throws {
        do {
            try await shelves.wait()
        } catch {
            throw URLError(.cancelled)
        }
    }

    private static func status(_ id: String) -> String {
        #"{"id":"\#(id)","created_at":"2026-01-01T00:00:00.000Z","account":{"id":"2","username":"bob","acct":"bob","display_name":"Bob","note":"","fields":[],"emojis":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0},"content":"<p>\#(id)</p>","spoiler_text":"","sensitive":false,"visibility":"public","media_attachments":[],"mentions":[],"tags":[],"emojis":[]}"#
    }
}
