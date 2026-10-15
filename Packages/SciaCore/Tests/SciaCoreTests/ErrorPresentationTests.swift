import Foundation
import Testing
@testable import SciaCore

/// 失敗を種類に分け、種類ごとの文言と小さく添える補足にする。HTMLの本文やDecodingErrorの文は出さない。
struct ErrorPresentationTests {
    @Test(arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed])
    func offline(code: URLError.Code) {
        let presentation = ErrorPresentation(URLError(code))

        #expect(presentation.message == "インターネットに接続できません。")
        #expect(presentation.code == "URLError \(code.rawValue)")
    }

    /// 止められている間の自動の読み込みは、いつまで待てば自動でやり直すかを伝える。
    @Test func automaticRequestsPaused() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let presentation = ErrorPresentation(AutomaticRequestsPaused(until: until))

        #expect(presentation.message == "短い間にリクエストが多すぎたため、サーバーに一時的に止められています。\(until.formatted(date: .omitted, time: .shortened))を過ぎたら自動で読み込み直します。")
        #expect(presentation.code == nil)
    }

    @Test func timedOut() {
        #expect(ErrorPresentation(URLError(.timedOut)).message == "サーバーから時間内に応答がありませんでした。")
    }

    @Test(arguments: [URLError.Code.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed])
    func unreachable(code: URLError.Code) {
        #expect(ErrorPresentation(URLError(code)).message == "サーバーに接続できませんでした。")
    }

    @Test func insecureConnection() {
        #expect(ErrorPresentation(URLError(.serverCertificateUntrusted)).message == "サーバーと安全に接続できませんでした。")
    }

    @Test func htmlErrorPageIsNotShown() {
        let error = MastodonAPIError.from(statusCode: 502, body: Data("<html><body><h1>502 Bad Gateway</h1></body></html>".utf8))
        let presentation = ErrorPresentation(error)

        #expect(presentation.message == "サーバーが一時的に応答できません。しばらく待ってからやり直してください。")
        #expect(presentation.code == "HTTP 502")
        #expect(!presentation.text.contains("<html>"))
    }

    @Test func rateLimited() {
        let presentation = ErrorPresentation(MastodonAPIError.from(statusCode: 429, body: Data(#"{"error":"Too many requests"}"#.utf8)))

        #expect(presentation.message == "短い間にリクエストが多すぎたため、サーバーに一時的に止められています。しばらく待ってからやり直してください。")
        #expect(presentation.code == "HTTP 429")
    }

    @Test(arguments: [404, 410, 501])
    func unsupported(statusCode: Int) {
        let presentation = ErrorPresentation(MastodonAPIError.from(statusCode: statusCode, body: Data(#"{"error":"Record not found"}"#.utf8)))

        #expect(presentation.message == "見つからないか、このサーバーでは使えません。")
    }

    @Test func unauthorized() {
        let presentation = ErrorPresentation(MastodonAPIError.from(statusCode: 401, body: Data(#"{"error":"The access token is invalid"}"#.utf8)))

        #expect(presentation.message == "サーバーがログインを受け付けませんでした。")
        #expect(presentation.code == "HTTP 401")
    }

    @Test func forbidden() {
        #expect(ErrorPresentation(MastodonAPIError.from(statusCode: 403, body: Data())).message == "サーバーがこの操作を許可しませんでした。")
    }

    /// 文字数の超過など、サーバーが理由をJSONで返したら、その理由を出す。
    @Test func validationErrorShowsServerReason() {
        let body = Data(#"{"error":"Validation failed: Text character limit of 500 exceeded"}"#.utf8)
        let presentation = ErrorPresentation(MastodonAPIError.from(statusCode: 422, body: body))

        #expect(presentation.message == "Validation failed: Text character limit of 500 exceeded")
        #expect(presentation.code == "HTTP 422")
    }

    @Test func otherClientErrorWithoutJSONReason() {
        let presentation = ErrorPresentation(MastodonAPIError.from(statusCode: 400, body: Data("<html>Bad Request</html>".utf8)))

        #expect(presentation.message == "サーバーがリクエストを受け付けませんでした。")
    }

    @Test func unreadableResponse() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The given data was not valid JSON."))
        let presentation = ErrorPresentation(error)

        #expect(presentation.message == "サーバーから届いた内容を読めませんでした。")
        #expect(!presentation.text.contains("JSON"))
    }

    /// アプリが自分で作った文言は、そのまま出す。
    @Test func ownLocalizedErrorIsShownAsIs() {
        struct Own: LocalizedError {
            var errorDescription: String? { "@alice@example.socialが見つかりませんでした。" }
        }

        #expect(ErrorPresentation(Own()) == ErrorPresentation(message: "@alice@example.socialが見つかりませんでした。", code: nil))
    }

    @Test func textAppendsCode() {
        #expect(ErrorPresentation(message: "読み込めませんでした。", code: "HTTP 503").text == "読み込めませんでした。（HTTP 503）")
        #expect(ErrorPresentation(message: "読み込めませんでした。", code: nil).text == "読み込めませんでした。")
    }
}
