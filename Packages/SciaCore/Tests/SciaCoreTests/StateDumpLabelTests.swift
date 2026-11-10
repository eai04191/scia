import Foundation
import Testing
@testable import SciaCore

/// 状態ダンプの表記は、状態の種類だけを書く。違和感レポートに入るので、URL、代替テキスト、ハンドル、サーバーが返した文言を出さない（docs/logging.md）。
struct StateDumpLabelTests {
    @Test func attachmentStatesHideURLAndDescription() {
        let media = MediaAttachment(id: "m1", type: .image, url: URL(string: "https://files.example.social/secret-path/m1.png"), previewUrl: URL(string: "https://files.example.social/secret-path/small.png"), description: "ひみつの代替テキスト")
        let states: [DraftAttachment.State] = [.uploading, .processing(serverID: "m1"), .uploaded(media), .failed(serverID: "m1"), .failed(serverID: nil)]

        #expect(states.map(\.dumpLabel) == ["uploading", "processing", "uploaded", "failed(accepted)", "failed"])
        for label in states.map(\.dumpLabel) { Self.expectNoPrivateValue(in: label) }
    }

    @Test func contentStatesHideServerMessageAndHandle() {
        let states: [TimelineContentState] = [.loading, .loaded, .regenerating, .failed(Self.rejected), .failed(Self.loggedOut), .failed(Self.rejected.leading("読み込めませんでした。")), .unavailable]

        #expect(states.map(\.dumpLabel) == ["loading", "loaded", "regenerating", "failed(HTTP 422)", "failed(HTTP 401 loggedOut)", "failed", "unavailable"])
        for label in states.map(\.dumpLabel) { Self.expectNoPrivateValue(in: label) }
    }

    @Test func footerStatesHideServerMessageAndHandle() {
        let states: [TimelineFooterState] = [.idle, .loading, .failed(Self.rejected), .failed(Self.loggedOut), .reachedEnd]

        #expect(states.map(\.dumpLabel) == ["idle", "loading", "failed(HTTP 422)", "failed(HTTP 401 loggedOut)", "reachedEnd"])
        for label in states.map(\.dumpLabel) { Self.expectNoPrivateValue(in: label) }
    }

    /// サーバーが理由をJSONで返した失敗。理由がそのまま文言になる。
    private static let rejected = ErrorPresentation(MastodonAPIError(statusCode: 422, message: "", serverMessage: "サーバーのひみつの文言"))
    /// 「別のアカウントで」使ったアカウントがログアウトされていた失敗。文言にハンドルが入る。
    private static let loggedOut = ErrorPresentation(MastodonAPIError(statusCode: 401, message: "", account: RequestAccount(id: "https://example.social#1", handle: "@secret@example.social", isOtherAccount: true)))

    private static func expectNoPrivateValue(in label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!label.contains("ひみつ"), sourceLocation: sourceLocation)
        #expect(!label.contains("secret"), sourceLocation: sourceLocation)
        #expect(!label.contains("example.social"), sourceLocation: sourceLocation)
    }
}
