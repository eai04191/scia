import Foundation
import Testing
@testable import SciaCore

/// 登録した順に応答を返し、受け取ったリクエストを記録するHTTPTransport。
actor StubTransport: HTTPTransport {
    struct Response {
        let statusCode: Int
        let body: Data
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = try #require(responses.first, "想定より多くリクエストされました: \(request)")
        responses.removeFirst()
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: next.statusCode, httpVersion: nil, headerFields: nil))
        return (next.body, response)
    }
}

extension StubTransport.Response {
    static func fixture(_ name: String, statusCode: Int = 200) throws -> Self {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return Self(statusCode: statusCode, body: try Data(contentsOf: url))
    }

    static func json(_ text: String, statusCode: Int) -> Self {
        Self(statusCode: statusCode, body: Data(text.utf8))
    }
}
