import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

@MainActor
struct ThreadControllerTests {
    private static let focus = StatusFactory.make(count: 1, startingAt: 100)[0]

    /// 引っぱって読み直すと、読んでいた途中の会話の読み込みを止めて読み直す。止めた読み込みが終わっても、読み直しの途中のままにし、
    /// つながったときに読み込みを重ねない。重ねると、引っぱった読み直しが止められ、読み終える前に更新コントロールが閉じる。
    @Test func pullToRefreshStaysLoadingAfterCancellingEarlierLoad() async throws {
        let transport = ThreadTransport()
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
        let client = MastodonClient(credential: credential, transport: transport)
        let connector = MessageQueueConnector()
        let streaming = StreamingClient(credential: credential, connector: connector)
        let streamingEndpoint = StreamingEndpoint(client: client)
        let streamingHub = StreamingHub(livePolicy: { TuningCatalog.liveUpdates(in: TuningStore(defaults: nil)) }) {
            streaming.open(baseURL: try await streamingEndpoint.url())
        }
        let (controller, viewController) = ThreadController.make(focus: Self.focus, client: client, streamingHub: streamingHub, tasks: TaskScope()) {}
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: viewController)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        let refreshControl = try #require(viewController.collectionView.refreshControl)

        controller.start()
        try await waitUntil { transport.context.waiterCount == 1 }
        let earlierLoad = try #require(controller.loadTask)
        refreshControl.beginRefreshing()
        refreshControl.sendActions(for: .valueChanged)
        try await waitUntil { transport.contextRequests == 2 }
        await earlierLoad.value

        // 止めた読み込みが終わってから、つながった知らせを届ける。知らせは申し込んだ順に届くため、後から申し込んだ相手に届いたら、スレッドも受け取っている。
        let connected = Mutex(false)
        let subscription = streamingHub.subscribe(.user) { activity in
            if activity == .connected { connected.withLock { $0 = true } }
        }
        defer { subscription.cancel() }
        transport.instance.open()
        try await waitUntil { connected.withLock { $0 } }

        #expect(transport.contextRequests == 2, "つながったときに、読み直しの途中の読み込みを止めて読み直しました")
        #expect(refreshControl.isRefreshing)

        transport.context.open()
        try await waitUntil { !refreshControl.isRefreshing }
        #expect(transport.contextRequests == 2)
    }

    /// ログアウトなどでセッションを閉じたら、開いているスレッドも、画面が積まれたままでも読み込みと購読をやめる。
    /// セッションが開いている画面を並べて止めていたころは、スレッドを止め忘れ、前のアカウントで読み続けていた。
    @Test func closingSessionStopsLoadAndSubscription() async throws {
        let transport = ThreadTransport()
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
        let client = MastodonClient(credential: credential, transport: transport)
        let streaming = StreamingClient(credential: credential, connector: MessageQueueConnector())
        let streamingEndpoint = StreamingEndpoint(client: client)
        let streamingHub = StreamingHub(livePolicy: { TuningCatalog.liveUpdates(in: TuningStore(defaults: nil)) }) {
            streaming.open(baseURL: try await streamingEndpoint.url())
        }
        let session = TaskScope()
        let (controller, viewController) = ThreadController.make(focus: Self.focus, client: client, streamingHub: streamingHub, tasks: session.child()) {}

        controller.start()
        try await waitUntil { transport.context.waiterCount == 1 }
        #expect(streamingHub.subscriptions == [.user])
        session.close()

        try await waitUntil { controller.runningTaskCount == 0 && transport.context.waiterCount == 0 }
        #expect(streamingHub.subscriptions.isEmpty)
        #expect(transport.contextRequests == 1)
        _ = viewController
    }
}

/// 会話とインスタンス情報の応答を、門を開けるまで止めるHTTPTransport。止めている間に取り消された要求は、URLSessionと同じく失敗させる。
private final class ThreadTransport: HTTPTransport {
    let context = Gate()
    let instance = Gate()
    private let requests = Mutex(0)

    var contextRequests: Int { requests.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let body: Data
        if url.path().hasSuffix("/context") {
            requests.withLock { $0 += 1 }
            do {
                try await context.wait()
            } catch {
                throw URLError(.cancelled)
            }
            body = Data(#"{"ancestors":[],"descendants":[]}"#.utf8)
        } else if url.path() == "/api/v2/instance" {
            try await instance.wait()
            body = Data(#"{"configuration":{"urls":{"streaming":"wss://example.social"}}}"#.utf8)
        } else {
            Issue.record("想定していないリクエストです: \(url)")
            body = Data()
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (body, response)
    }
}
