import Foundation
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 通知の一覧で、切れていた間の補完が手元とつながらなかったときのギャップを確かめる。
@MainActor
@Suite(.serialized)
struct NotificationsControllerTests {
    private var tolerance: CGFloat { 1 / max(UITraitCollection.current.displayScale, 1) }

    /// 最初に読む60件。
    private static let initialIDs = Array((1_000..<1_060).reversed())
    /// つないだときの補完で読む40件。1ページで満杯なので、手元とつながったか分からない。
    private static let latestIDs = Array((3_000..<3_040).reversed())
    /// ギャップの中にある10件。
    private static let gapIDs = Array((2_000..<2_010).reversed())

    private func makeController() throws -> NotificationsController {
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
        let client = MastodonClient(credential: credential, transport: NotificationsTransport(initial: Self.initialIDs, latest: Self.latestIDs, inGap: Self.gapIDs))
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(1, for: TuningCatalog.fillPageLimit)
        let streaming = StreamingClient(credential: credential, connector: MessageQueueConnector())
        let streamingEndpoint = StreamingEndpoint(client: client)
        let streamingHub = StreamingHub(livePolicy: { TuningCatalog.liveUpdates(in: tuning) }) {
            streaming.open(baseURL: try await streamingEndpoint.url())
        }
        return NotificationsController(client: client, streamingHub: streamingHub, tuning: tuning, clock: TestClock()) {}
    }

    private func windowMinY(of id: TimelineEntry.ID, in controller: NotificationsController, window: UIWindow) throws -> CGFloat {
        let collectionView = controller.viewController.collectionView
        collectionView.layoutIfNeeded()
        let index = try #require(controller.viewController.displayedItemIDs.firstIndex(of: id))
        let cell = try #require(collectionView.cellForItem(at: IndexPath(item: index, section: 0)))
        return cell.convert(cell.bounds, to: window).minY
    }

    /// 補完が手元とつながらなければ、手元の通知を残してギャップを置く。
    /// ギャップを押して読んだ通知を足しても、押した位置の側で読んでいた行は動かない。上半分で押したら下の行、下半分で押したら上の行を保つ。
    @Test(arguments: [TimelineStore.GapDirection.fromOlder, .fromNewer])
    func loadingGapKeepsReadingRow(direction: TimelineStore.GapDirection) async throws {
        let controller = try makeController()
        defer { controller.stop() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: controller.viewController)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        controller.start()
        // 最初の読み込みのあと、つながったときの補完でギャップが入る。
        try await waitUntil { controller.viewController.displayedItemIDs.count == Self.initialIDs.count + Self.latestIDs.count + 1 }
        try await waitUntil { !controller.viewController.isScrollingToTop }
        let ids = controller.viewController.displayedItemIDs
        let gapIndex = try #require(ids.firstIndex { if case .gap = $0 { true } else { false } })
        #expect(ids[gapIndex - 1] == .notification(String(Self.latestIDs[Self.latestIDs.count - 1])))
        #expect(ids[gapIndex + 1] == .notification(String(Self.initialIDs[0])), "手元の通知を捨てました")
        guard case .gap(let gapID) = ids[gapIndex] else { return }

        let collectionView = controller.viewController.collectionView
        collectionView.scrollToItem(at: IndexPath(item: gapIndex, section: 0), at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        let kept = direction == .fromOlder ? ids[gapIndex + 1] : ids[gapIndex - 1]
        let before = try windowMinY(of: kept, in: controller, window: window)

        controller.viewController.onGapSelect?(gapID, direction)
        let expected = (Self.latestIDs + Self.gapIDs + Self.initialIDs).map { TimelineEntry.ID.notification(String($0)) }
        try await waitUntil { controller.viewController.displayedItemIDs == expected }

        let after = try windowMinY(of: kept, in: controller, window: window)
        #expect(abs(after - before) <= tolerance, "読んでいた行が\(after - before)pt動きました")
    }
}

/// 通知の読み込みに、決まった通知を返すHTTPTransport。ギャップの中は、どちらの端から読んでも同じ通知を返し、次は0件を返す。
private struct NotificationsTransport: HTTPTransport {
    let initial: [Int]
    let latest: [Int]
    let inGap: [Int]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        let body: Data
        switch url.path() {
        case "/api/v2/notifications":
            let gapTop = String(latest[latest.count - 1])
            let gapBottom = String(initial[0])
            let ids: [Int] = switch (query["max_id"], query["since_id"], query["min_id"]) {
            case (nil, nil, nil): initial
            case (nil, .some, nil): latest
            case (gapTop, gapBottom, nil), (gapTop, nil, gapBottom): inGap
            default: []
            }
            body = try Self.groupedBody(ids)
        case "/api/v1/markers":
            body = Data("{}".utf8)
        case "/api/v2/instance":
            body = Data(#"{"configuration":{"urls":{"streaming":"wss://example.social"}}}"#.utf8)
        default:
            body = Data("{}".utf8)
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (body, response)
    }

    /// フォローの通知を、まとまりにしない形で並べた応答。
    private static func groupedBody(_ ids: [Int]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/avatars/bob.png"))
        let accounts = try JSONSerialization.jsonObject(with: encoder.encode([account]))
        let groups = ids.map { id in
            [
                "group_key": "ungrouped-\(id)",
                "notifications_count": 1,
                "type": "follow",
                "page_max_id": String(id),
                "page_min_id": String(id),
                "latest_page_notification_at": "2026-10-13T03:21:45.123Z",
                "sample_account_ids": ["2"],
            ] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: ["accounts": accounts, "statuses": [], "notification_groups": groups])
    }
}
