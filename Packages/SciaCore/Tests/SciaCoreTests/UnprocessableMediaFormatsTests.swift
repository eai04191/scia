import Foundation
import Testing
@testable import SciaCore

@MainActor
struct UnprocessableMediaFormatsTests {
    private func instance() throws -> URL {
        try #require(URL(string: "https://example.social"))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "UnprocessableMediaFormatsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func remembersAcrossLaunchesForTheSameVersion() throws {
        let defaults = try makeDefaults()
        UnprocessableMediaFormats(defaults: defaults, instance: try instance()).record("image/heic", serverVersion: "4.7.3")
        let relaunched = UnprocessableMediaFormats(defaults: defaults, instance: try instance())
        #expect(relaunched.mimeTypes(serverVersion: "4.7.3") == ["image/heic"])
    }

    /// サーバーが更新されたら、直ったかもしれないので、もう一度送ってみる。
    @Test func triesAgainWhenTheServerVersionChanges() throws {
        let formats = UnprocessableMediaFormats(defaults: try makeDefaults(), instance: try instance())
        formats.record("image/heic", serverVersion: "4.7.3")
        #expect(formats.mimeTypes(serverVersion: "4.7.4").isEmpty)
    }

    /// 新しい版でまた失敗したら、版を改めて覚え直し、古い版の記録は残さない。
    @Test func replacesTheEntryOfAnOlderVersion() throws {
        let formats = UnprocessableMediaFormats(defaults: try makeDefaults(), instance: try instance())
        formats.record("image/heic", serverVersion: "4.7.3")
        formats.record("image/heic", serverVersion: "4.7.4")
        #expect(formats.entries.map(\.serverVersion) == ["4.7.4"])
    }

    @Test func keepsServersApart() throws {
        let defaults = try makeDefaults()
        UnprocessableMediaFormats(defaults: defaults, instance: try instance()).record("image/heic", serverVersion: "4.7.3")
        let other = UnprocessableMediaFormats(defaults: defaults, instance: try #require(URL(string: "https://other.example")))
        #expect(other.mimeTypes(serverVersion: "4.7.3").isEmpty)
    }

    @Test func replacesOnlyProcessingFailuresOfReplaceableFormats() {
        let processing = MediaUploadError.processingFailed(MastodonAPIError(statusCode: 500, message: "Error processing thumbnail for uploaded media"))
        #expect(UnprocessableMediaFormats.shouldReplaceWithJPEG(mimeType: "image/heic", error: processing))
        #expect(UnprocessableMediaFormats.shouldReplaceWithJPEG(mimeType: "image/avif", error: processing))
        // JPEGやPNGの処理の失敗は、形式を変えても直らない。
        #expect(!UnprocessableMediaFormats.shouldReplaceWithJPEG(mimeType: "image/jpeg", error: processing))
        // 処理の完了を待つ間の失敗（422）や、受け付けなかったとき（形式やサイズ）は、500で処理に失敗したのとは別の原因のことがある。
        let waiting = MediaUploadError.processingFailed(MastodonAPIError(statusCode: 422, message: ""))
        #expect(!UnprocessableMediaFormats.shouldReplaceWithJPEG(mimeType: "image/heic", error: waiting))
        let rejected = MediaUploadError.rejected(MastodonAPIError(statusCode: 422, message: ""))
        #expect(!UnprocessableMediaFormats.shouldReplaceWithJPEG(mimeType: "image/heic", error: rejected))
        #expect(!UnprocessableMediaFormats.shouldReplaceWithJPEG(mimeType: "image/heic", error: URLError(.timedOut)))
    }
}
