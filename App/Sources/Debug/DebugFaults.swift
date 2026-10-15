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

    /// 決めると、以後のREST APIのリクエストに、そのステータスコードとHTMLのエラーページを返す。プロキシやサーバーの障害を再現する。
    private static let failingStatusCode = Mutex<Int?>(nil)

    static var failingStatus: Int? { failingStatusCode.withLock { $0 } }

    static func fail(withStatus statusCode: Int) {
        failingStatusCode.withLock { $0 = statusCode }
    }

    /// 立てると、以後のホームと通知の応答のうち、3件に1件を読めない形に壊す。読めなかった投稿や通知の行を、実際の読み込みの経路で確かめる。
    private static let corruptsListElements = Mutex(false)

    static var isCorruptingListElements: Bool { corruptsListElements.withLock { $0 } }

    static func corruptListElements() {
        corruptsListElements.withLock { $0 = true }
    }

    /// 配列の3件に1件の`created_at`を、日時として読めない値に変える。IDとURLは残すので、読めなかった行として並ぶ。
    static func corrupt(_ data: Data) -> Data {
        guard var elements = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return data }
        for index in elements.indices where index % 3 == 1 {
            elements[index]["created_at"] = "壊れた日時"
        }
        return (try? JSONSerialization.data(withJSONObject: elements)) ?? data
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
        if let statusCode = DebugFaults.failingStatus,
           let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "text/html"]) {
            return (Data("<html><body><h1>\(statusCode)</h1><p>nginx</p></body></html>".utf8), response)
        }
        let (data, response) = try await base.send(request)
        let path = request.url?.path() ?? ""
        if DebugFaults.isCorruptingListElements, path.hasSuffix("api/v1/timelines/home") || path.hasSuffix("api/v1/notifications") {
            return (DebugFaults.corrupt(data), response)
        }
        return (data, response)
    }
}
#endif
