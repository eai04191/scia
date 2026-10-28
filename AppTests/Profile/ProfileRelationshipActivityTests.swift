import Foundation
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// プロフィールを開いて、フォローの関係を待つ間のフォローのボタンの中のアクティビティインジケータ。
@Suite(.scratch)
@MainActor
struct ProfileRelationshipActivityTests {
    private static let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)

    @MainActor
    private struct Opened {
        let controller: ProfileController
        let viewController: TimelineViewController
        let window: UIWindow
        let transport: ProfileTransport
        let tasks: TaskScope
        let clock: TestClock

        var delay: Duration { .seconds(viewController.tuning.value(of: TuningCatalog.profileRelationshipActivityDelay)) }

        /// インジケータを出すまでの待ち。一覧の相対時刻を1秒ごとに書き直す待ちも同じ時計を使うため、待つ時間の内に締め切りが来るものだけを数える。
        var relationshipWaits: Int { clock.sleeperCount(dueWithin: delay) }

        /// フォローのボタンに関係が届いて、「フォロー中」になった。
        var showsFollowing: Bool {
            (try? button().state?.title) == "フォロー中"
        }

        func button() throws -> ProfileFollowButton {
            try #require(viewController.view.descendants(of: ProfileFollowButton.self).first)
        }

        /// フォローのボタンの中にインジケータを出している。
        func showsIndicator() throws -> Bool {
            try button().state?.showsActivity == true
        }

        func close() {
            tasks.close()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func open(clock: TestClock, cached: Relationship? = nil, relationshipsBody: String = ProfileTransport.following) throws -> Opened {
        let transport = ProfileTransport(relationshipsBody: relationshipsBody)
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
        let cache = RelationshipCache { _ in [] }
        cache[Self.account.id] = cached
        let (controller, viewController) = ProfileController.make(
            account: Self.account,
            client: client,
            relationshipCache: cache,
            settings: .isolated(),
            tasks: tasks,
            onError: { _, _ in },
            onUnauthorized: {}
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

    /// すぐ届いたときに一瞬だけ回らないよう、待つ時間が過ぎるまでは出さない。過ぎても届かなければ出し、届いたら消す。
    @Test func showsIndicatorOnlyAfterDelay() async throws {
        let clock = TestClock()
        let opened = try open(clock: clock)
        defer { opened.close() }
        try await waitUntil { opened.relationshipWaits == 1 }

        clock.advance(by: opened.delay - .milliseconds(1))
        #expect(opened.relationshipWaits == 1)
        #expect(try !opened.showsIndicator())

        clock.advance(by: .milliseconds(1))
        try await waitUntil { try opened.showsIndicator() }

        opened.transport.relationships.open()
        try await waitUntil { opened.showsFollowing }
        #expect(try !opened.showsIndicator())
    }

    /// 待つ時間より前に届いたら、インジケータを出さず、待つ処理も残さない。
    @Test func arrivingBeforeDelayNeverShowsIndicator() async throws {
        let clock = TestClock()
        let opened = try open(clock: clock)
        defer { opened.close() }
        try await waitUntil { opened.relationshipWaits == 1 }

        opened.transport.relationships.open()
        try await waitUntil { opened.showsFollowing }
        let running = opened.controller.runningTaskCount
        clock.advance(by: opened.delay)
        // 待ちが明けて、関係が届いていたことを確かめて終わるまで待つ。
        try await waitUntil { opened.controller.runningTaskCount == running - 1 }

        #expect(try !opened.showsIndicator())
    }

    /// 相手がサーバーの応答に入らなかった（凍結や削除の予定で、Mastodonが返さない）ときは、関係は分からないまま読み込みを終える。
    /// 読み込み中を示し続けないよう、インジケータを消す。
    @Test func emptyResponseStopsIndicator() async throws {
        let clock = TestClock()
        let opened = try open(clock: clock, relationshipsBody: "[]")
        defer { opened.close() }
        try await waitUntil { opened.relationshipWaits == 1 }
        clock.advance(by: opened.delay)
        try await waitUntil { try opened.showsIndicator() }

        opened.transport.relationships.open()
        try await waitUntil { try !opened.showsIndicator() }
    }

    /// 一度読んだ関係を覚えていれば、すぐにボタンを出すので、待たない。
    @Test func cachedRelationshipDoesNotWait() throws {
        let clock = TestClock()
        let opened = try open(clock: clock, cached: Relationship(id: Self.account.id, following: true))
        defer { opened.close() }

        #expect(opened.relationshipWaits == 0)
        #expect(try !opened.showsIndicator())
    }
}

/// 関係の読み込みを門で止める通信。ほかの読み込みは失敗させる。プロフィールの画面は、読めなかった部分をログに残して続ける。
private final class ProfileTransport: HTTPTransport {
    static let following = #"[{"id":"2","following":true,"showing_reblogs":true,"notifying":false,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"requested":false,"note":""}]"#

    let relationships = Gate()
    private let relationshipsBody: String

    init(relationshipsBody: String) {
        self.relationshipsBody = relationshipsBody
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        guard url.path() == "/api/v1/accounts/relationships" else { throw URLError(.notConnectedToInternet) }
        do {
            try await relationships.wait()
        } catch {
            throw URLError(.cancelled)
        }
        let body = Data(relationshipsBody.utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (body, response)
    }
}
