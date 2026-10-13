import Foundation
import SciaCore
import Testing
@testable import Scia

@MainActor
@Suite(.serialized)
struct HomeTimelineControllerTests {
    private func makeClient(_ transport: some HTTPTransport) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport
        )
    }

    @Test func emptyRegeneratingHomeOffersReload() async throws {
        let transport = ScriptedTransport { _ in (206, Data("[]".utf8)) }
        let controller = HomeTimelineController(client: try makeClient(transport)) { _, _ in }

        controller.start()
        try await waitUntil { controller.viewController.contentState != .loading }

        #expect(controller.viewController.contentState == .regenerating)
    }

    @Test func stoppedControllerDoesNotReportUnauthorized() async throws {
        let gate = ResponseGate()
        let transport = ScriptedTransport { _ in
            await gate.wait()
            return (401, Data(#"{"error":"The access token is invalid"}"#.utf8))
        }
        let reported = Box(false)
        let controller = HomeTimelineController(client: try makeClient(transport)) { _, _ in
            reported.value = true
        }

        controller.start()
        await gate.waitUntilWaiting()
        controller.stop()
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(!reported.value)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "条件が満たされませんでした")
    }
}

@MainActor
private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// 応答をクロージャで組み立てるHTTPTransport。
private struct ScriptedTransport: HTTPTransport {
    let respond: @Sendable (URLRequest) async -> (Int, Data)

    init(_ respond: @escaping @Sendable (URLRequest) async -> (Int, Data)) {
        self.respond = respond
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (statusCode, body) = await respond(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
        return (body, response)
    }
}

/// 応答を途中で止めておくための門。
private actor ResponseGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            isWaiting = true
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilWaiting() async {
        if isWaiting { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}
