import Foundation
import SciaCore
import Synchronization
import Testing
import UIKit
@testable import Scia

/// ブックマークやお気に入りの一覧で、先頭に足しても読んでいる行が動かないことを確かめる。決まりはdocs/tabs.mdの「ブックマークとお気に入り」にある。
@MainActor
@Suite(.serialized)
struct SavedStatusesControllerTests {
    private var tolerance: CGFloat { 1 / max(UITraitCollection.current.displayScale, 1) }

    /// 一覧に載せる60件。ブックマークした印を付ける。
    private static let saved = StatusFactory.make(count: 60, startingAt: 1_000).map { $0.settingBookmarked(true) }

    /// サーバーに加わった、一覧の先頭に入る投稿。
    private static let newest = StatusFactory.make(count: 1, startingAt: 2_000).map { $0.settingBookmarked(true) }

    private func makeController(pages: [[Status]]) throws -> SavedStatusesController {
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let bodies = try pages.map { try encoder.encode($0) }
        let index = Mutex(0)
        let transport = PagedTransport { _ in
            index.withLock { index in
                defer { index += 1 }
                return bodies[min(index, bodies.count - 1)]
            }
        }
        return SavedStatusesController(kind: .bookmarks, client: MastodonClient(credential: credential, transport: transport)) {}
    }

    /// 一覧をウィンドウに載せて読み込み、最上部にいる状態にする。
    private func show(_ controller: SavedStatusesController) async throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: controller.viewController)
        window.makeKeyAndVisible()
        controller.startIfNeeded()
        try await waitUntil { controller.viewController.displayedItemIDs.count == Self.saved.count }
        controller.viewController.collectionView.layoutIfNeeded()
        return window
    }

    private func windowMinY(of id: TimelineEntry.ID, in controller: SavedStatusesController, window: UIWindow) throws -> CGFloat {
        let collectionView = controller.viewController.collectionView
        collectionView.layoutIfNeeded()
        let index = try #require(controller.viewController.displayedItemIDs.firstIndex(of: id))
        let cell = try #require(collectionView.cellForItem(at: IndexPath(item: index, section: 0)))
        return cell.convert(cell.bounds, to: window).minY
    }

    /// ほかのタブで付けた投稿を先頭に入れても、最上部で読んでいた行は動かない。
    @Test func settledInsertAtTopKeepsReadingRow() async throws {
        let controller = try makeController(pages: [Self.saved])
        let window = try await show(controller)
        defer { window.isHidden = true }
        let top = TimelineEntry.ID.status(Self.saved[0].id)
        let before = try windowMinY(of: top, in: controller, window: window)

        controller.statusDidSettle(.bookmark, Self.newest[0])

        #expect(controller.viewController.displayedItemIDs.first == .status(Self.newest[0].id))
        // 最上部での追従は、足した直後は位置を保ち、そのあと最上部へ動かすため、動き終わるまで待ってから測る。
        try await Task.sleep(for: .seconds(1))
        let after = try windowMinY(of: top, in: controller, window: window)
        #expect(abs(after - before) <= tolerance, "読んでいた行が\(after - before)pt動きました")
    }

    /// タブで開き直して、ほかの端末で付けた投稿を先頭に足しても、最上部で読んでいた行は動かない。
    @Test func refreshAtTopKeepsReadingRow() async throws {
        let controller = try makeController(pages: [Self.saved, Self.newest + Self.saved])
        let window = try await show(controller)
        defer { window.isHidden = true }
        let top = TimelineEntry.ID.status(Self.saved[0].id)
        let before = try windowMinY(of: top, in: controller, window: window)

        controller.setShown(true)
        try await waitUntil { controller.viewController.displayedItemIDs.count == Self.saved.count + 1 }

        #expect(controller.viewController.displayedItemIDs.first == .status(Self.newest[0].id))
        // 最上部での追従は、足した直後は位置を保ち、そのあと最上部へ動かすため、動き終わるまで待ってから測る。
        try await Task.sleep(for: .seconds(1))
        let after = try windowMinY(of: top, in: controller, window: window)
        #expect(abs(after - before) <= tolerance, "読んでいた行が\(after - before)pt動きました")
    }

    /// 見ている間に外して受け付けられた行は残し、見ていない一覧で外して受け付けられた行はその場で消す。
    @Test func unsavedRowStaysOnlyWhileShown() async throws {
        let controller = try makeController(pages: [Self.saved, Self.saved])
        let window = try await show(controller)
        defer { window.isHidden = true }
        controller.setShown(true)
        let first = Self.saved[0].settingBookmarked(false)
        let second = Self.saved[1].settingBookmarked(false)

        // 押したときに印を外し、サーバーが受け付けたら知らせる。StatusInteractionsと同じ順に送る。
        controller.updateStatus(first.id) { $0.settingBookmarked(false) }
        controller.statusDidSettle(.bookmark, first)
        #expect(controller.viewController.displayedItemIDs.contains(.status(first.id)))

        controller.setShown(false)
        #expect(!controller.viewController.displayedItemIDs.contains(.status(first.id)))

        controller.updateStatus(second.id) { $0.settingBookmarked(false) }
        controller.statusDidSettle(.bookmark, second)
        #expect(!controller.viewController.displayedItemIDs.contains(.status(second.id)))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "条件が満たされませんでした")
    }
}

/// 呼ばれるたびに、渡した本文を200で返す。
private struct PagedTransport: HTTPTransport {
    let body: @Sendable (URLRequest) -> Data

    init(_ body: @escaping @Sendable (URLRequest) -> Data) {
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (body(request), response)
    }
}
