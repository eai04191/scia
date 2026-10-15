import Foundation
import Testing
@testable import SciaCore

/// 登録した順に応答を返し、受け取ったリクエストを記録するHTTPTransport。
actor StubTransport: HTTPTransport {
    struct Response {
        let statusCode: Int
        let body: Data
        var headers: [String: String] = [:]
        /// 応答の代わりに投げる、通信の失敗。
        var error: URLError?
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
        if let error = next.error {
            throw error
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: next.statusCode, httpVersion: nil, headerFields: next.headers))
        return (next.body, response)
    }
}

extension StubTransport.Response {
    static func fixture(_ name: String, statusCode: Int = 200) throws -> Self {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return Self(statusCode: statusCode, body: try Data(contentsOf: url))
    }

    static func failure(_ code: URLError.Code) -> Self {
        Self(statusCode: 0, body: Data(), error: URLError(code))
    }

    static func json(_ text: String, statusCode: Int, headers: [String: String] = [:]) -> Self {
        Self(statusCode: statusCode, body: Data(text.utf8), headers: headers)
    }
}
