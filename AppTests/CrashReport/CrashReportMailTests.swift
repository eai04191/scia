import Foundation
import Testing
@testable import Scia

struct CrashReportMailTests {
    @Test func 本文の改行と記号を保ってメールのURLにする() throws {
        let body = "本文は含まれていません。\n\n{\"a\": \"b&c=d\"}"
        let url = try #require(CrashReportMail.url(to: "dev@example.com", body: body))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == "dev@example.com")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == body.replacingOccurrences(of: "\n", with: "\r\n"))
        // mailtoの改行はCRLFと決まっている（RFC 6068）。LFだけだとGmailで改行が消えた。
        #expect(url.absoluteString.contains("%0D%0A"))
    }
}
