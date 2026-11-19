import Foundation
import Testing
@testable import SciaCore

struct NotificationLayoutTests {
    private let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil, avatarStatic: nil)

    private func notification(_ type: MastodonNotification.Kind, hasStatus: Bool = true) -> MastodonNotification {
        let status = Status(id: "10", createdAt: Date(timeIntervalSince1970: 0), account: account, content: "<p>本文</p>", spoilerText: "", url: nil)
        return MastodonNotification(id: "n", type: type, createdAt: Date(timeIntervalSince1970: 0), account: account, status: hasStatus ? status : nil)
    }

    /// 相手の投稿を対象にする通知と、投票の終了の通知は、投稿と同じ見た目にする。
    @Test(arguments: [MastodonNotification.Kind.mention, .status, .quote, .update, .poll])
    func othersPostsAndEndedPollsLookLikePosts(_ type: MastodonNotification.Kind) {
        #expect(notification(type).layout == .post)
    }

    /// 自分の投稿が対象の通知は、その投稿を再掲する。引用した投稿の編集は、引用した自分の投稿が対象になる。
    @Test(arguments: [MastodonNotification.Kind.favourite, .reblog, .emojiReaction, .quotedUpdate])
    func reactionsQuoteThePost(_ type: MastodonNotification.Kind) {
        #expect(notification(type).layout == .quoted)
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
