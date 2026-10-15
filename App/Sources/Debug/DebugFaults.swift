#if DEBUG
import Foundation
import SciaCore
import Synchronization

/// 検証のため、APIの応答をわざと失敗させる。起動し直すと戻る。
enum DebugFaults {
    /// 立てると、以後のREST APIのリクエストに401を返す。トークンが無効になった状態を、ログインし直さずに再現する。
    private static let rejectsAsUnauthorized = Mutex(false)

    static var isRejectingAsUnauthorized: Bool { rejectsAsUnauthorized.withLock { $0 } }

    static func rejectAsUnauthorized() {
        rejectsAsUnauthorized.withLock { $0 = true }
    }
}

/// `DebugFaults`に従って失敗を返すHTTPTransport。
struct FaultInjectingTransport: HTTPTransport {
    let base: any HTTPTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if DebugFaults.isRejectingAsUnauthorized,
           let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil) {
            return (Data(#"{"error":"The access token is invalid"}"#.utf8), response)
        }
        return try await base.send(request)
    }
}
#endif
