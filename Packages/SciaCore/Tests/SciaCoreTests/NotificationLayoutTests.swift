import Foundation
import Testing
@testable import SciaCore

struct NotificationLayoutTests {
    private let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil, avatarStatic: nil)

    private func notification(_ type: MastodonNotification.Kind, hasStatus: Bool = true) -> MastodonNotification {
        let status = Status(id: "10", createdAt: Date(timeIntervalSince1970: 0), account: account, content: "<p>本文</p>", spoilerText: "", url: nil)
        return MastodonNotification(id: "n", type: type, createdAt: Date(timeIntervalSince1970: 0), account: account, status: hasStatus ? status : nil)
    }

    @Test(arguments: [MastodonNotification.Kind.mention, .status, .quote])
    func conversationsLookLikePosts(_ type: MastodonNotification.Kind) {
        #expect(notification(type).layout == .post)
    }

    @Test(arguments: [MastodonNotification.Kind.favourite, .reblog, .update, .quotedUpdate])
    func reactionsQuoteThePost(_ type: MastodonNotification.Kind) {
        #expect(notification(type).layout == .quoted(showsPollResults: false))
    }

    @Test func endedPollQuotesThePostWithResults() {
        #expect(notification(.poll).layout == .quoted(showsPollResults: true))
    }

    @Test(arguments: [MastodonNotification.Kind.follow, .followRequest, .other("admin.sign_up")])
    func accountEventsShowOnlyTheHeader(_ type: MastodonNotification.Kind) {
        #expect(notification(type, hasStatus: false).layout == .headerOnly)
    }

    /// 対象の投稿が消えたなどで届かなかったメンションは、出す投稿がないため、誰が何をしたかの行だけにする。
    @Test func mentionWithoutStatusShowsOnlyTheHeader() {
        #expect(notification(.mention, hasStatus: false).layout == .headerOnly)
    }
}
