import Foundation
import SciaCore

enum CrashReportMail {
    static let subject = CrashReportTexts.mailSubject

    /// 使う人が既定にしたメールアプリで開くURL。
    static func url(to address: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body.replacingOccurrences(of: "\n", with: "\r\n"))]
        return components.url
    }
}
