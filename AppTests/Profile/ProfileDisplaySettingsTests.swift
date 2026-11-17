import Foundation
import Synchronization
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 設定の「プロフィール」の、棚と固定された投稿の出し方。開いているプロフィールでも、切り替えたらすぐ反映する。
@Suite(.scratch, .failureState)
@MainActor
struct ProfileDisplaySettingsTests {
    private static let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)

    @MainActor
    private struct Opened {
        let viewController: TimelineViewController
        let window: UIWindow
        let tasks: TaskScope
        let clock: TestClock
        let settings: AppSettings
        let transport: SettingsShelvesTransport

        var header: ProfileHeaderView? {
            var views: [UIView] = [viewController.view]
            while let view = views.popLast() {
                if let header = view as? ProfileHeaderView { return header }
                views.append(contentsOf: view.subviews)
            }
            return nil
        }

        func close() {
            tasks.close()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func open(configure: (AppSettings) -> Void = { _ in }) throws -> Opened {
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
        let transport = SettingsShelvesTransport()
        let client = MastodonClient(credential: credential, transport: transport)
        let tasks = TaskScope()
        let settings = AppSettings.isolated()
        configure(settings)
        let (controller, viewController) = ProfileController.make(
            account: Self.account,
            client: client,
            relationshipCache: RelationshipCache { _ in [] },
            settings: settings,
            tasks: tasks,
            onError: { _, _ in }
        )
        let clock = TestClock()
        viewController.clock = clock
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: viewController)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.start()
        return Opened(viewController: viewController, window: window, tasks: tasks, clock: clock, settings: settings, transport: transport)
    }

    /// タイムラインを出すまで待つ。最初に出すときは見える行のアイコンを待つので、アイコンの待ちの上限まで時計を進める。
    private func waitUntilRevealed(_ opened: Opened) async throws {
        try await waitUntil {
            opened.clock.advance(by: .seconds(1))
            return opened.viewController.displayedItemIDs.contains(.status("10"))
        }
    }

    @Test func hidesFeaturedShelvesWhenTurnedOffAndShowsThemWhenTurnedOn() async throws {
        let opened = try open { settings in
            settings.showsProfileFeaturedTags = false
            settings.showsProfileEndorsements = false
        }
        defer { opened.close() }
        try await waitUntilRevealed(opened)
        let header = try #require(opened.header)
        #expect(header.shownShelves == [.pinned])
        // 隠した棚は読まない。
        #expect(opened.transport.requestedPaths.isDisjoint(with: [SettingsShelvesTransport.featuredTagsPath, SettingsShelvesTransport.endorsementsPath]))

        opened.settings.showsProfileFeaturedTags = true
        try await waitUntil { header.shownShelves == [.pinned, .featuredTags] }

        opened.settings.showsProfileEndorsements = true
        try await waitUntil { header.shownShelves == [.pinned, .featuredTags, .endorsements] }
    }
}

/// 固定された投稿、注目のハッシュタグ、紹介しているユーザー、投稿を1件ずつ返す。
private final class SettingsShelvesTransport: HTTPTransport {
    static let featuredTagsPath = "/api/v1/accounts/2/featured_tags"
    static let endorsementsPath = "/api/v1/accounts/2/endorsements"
    private let paths = Mutex<Set<String>>([])

    /// 読みに来たパス。
    var requestedPaths: Set<String> { paths.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        paths.withLock { _ = $0.insert(url.path()) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body: String
        switch url.path() {
        case Self.featuredTagsPath:
            body = #"[{"id":"1","name":"scia","statuses_count":"3","url":"https://example.social/@bob/tagged/scia"}]"#
        case Self.endorsementsPath:
            body = "[\(Self.account("3"))]"
        case "/api/v1/accounts/2/statuses" where query.contains { $0.name == "pinned" }:
            body = "[\(Self.status("5"))]"
        case "/api/v1/accounts/2/statuses":
            body = query.contains { $0.name == "max_id" || $0.name == "since_id" } ? "[]" : "[\(Self.status("10"))]"
        default:
            throw URLError(.notConnectedToInternet)
        }
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }

    private static func account(_ id: String) -> String {
        #"{"id":"\#(id)","username":"user\#(id)","acct":"user\#(id)","display_name":"User \#(id)","note":"","fields":[],"emojis":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0}"#
    }

    private static func status(_ id: String) -> String {
        #"{"id":"\#(id)","created_at":"2026-01-01T00:00:00.000Z","account":\#(account("2")),"content":"<p>\#(id)</p>","spoiler_text":"","sensitive":false,"visibility":"public","media_attachments":[],"mentions":[],"tags":[],"emojis":[]}"#
    }
}
