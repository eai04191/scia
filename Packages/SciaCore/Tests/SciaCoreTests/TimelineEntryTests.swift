import Foundation
import Testing
@testable import SciaCore

/// タイムラインの項目から、投稿と人を取り出す。
struct TimelineEntryTests {
    private func account(_ id: String, _ acct: String) -> Account {
        Account(id: id, username: acct, acct: acct, displayName: acct, avatar: URL(string: "https://example.social/\(id).png"))
    }

    private func status(_ id: String = "10", account: Account? = nil, mentions: [Mention] = [], reblog: Status? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account ?? self.account("1", "alice"), content: "", spoilerText: "", url: nil, mentions: mentions, reblog: reblog)
    }

    private func notification(_ type: MastodonNotification.Kind, from account: Account, status: Status? = nil) -> MastodonNotification {
        MastodonNotification(id: "1", type: type, createdAt: Date(timeIntervalSince1970: 0), account: account, status: status)
    }

    /// 投稿として並ぶ項目の投稿は、固定された投稿を含み、通知の対象の投稿を含まない。
    @Test func postStatusCoversPostsAndPinnedPosts() {
        let post = status()

        #expect(TimelineEntry.status(post).postStatus == post)
        #expect(TimelineEntry.pinned(post).postStatus == post)
        #expect(TimelineEntry.notification(notification(.mention, from: account("2", "bob"), status: post)).postStatus == nil)
        #expect(TimelineEntry.account(account("2", "bob")).postStatus == nil)
        #expect(TimelineEntry.gap(TimelineGap(newerID: "20", olderID: "10")).postStatus == nil)
    }

    /// 項目が指す投稿は、通知なら対象の投稿。ブーストは元の投稿にしない。
    @Test func targetStatusCoversNotifications() {
        let boost = status("11", reblog: status("10"))

        #expect(TimelineEntry.status(boost).targetStatus == boost)
        #expect(TimelineEntry.pinned(boost).targetStatus == boost)
        #expect(TimelineEntry.notification(notification(.mention, from: account("2", "bob"), status: boost)).targetStatus == boost)
        #expect(TimelineEntry.notification(notification(.follow, from: account("2", "bob"))).targetStatus == nil)
        #expect(TimelineEntry.account(account("2", "bob")).targetStatus == nil)
        #expect(TimelineEntry.gap(TimelineGap(newerID: "20", olderID: "10")).targetStatus == nil)
    }

    /// メンションされたユーザーのアイコンは、タイムラインのほかの項目にいるその人のアカウントから取る。ブーストされた投稿を書いた人と、通知した人からも探す。
    @Test func accountIsFoundInOtherEntries() {
        let boost = status(reblog: status(account: account("3", "carol")))
        let entries: [TimelineEntry] = [.status(boost), .notification(notification(.follow, from: account("4", "dave")))]

        #expect(entries.account(withID: "3")?.acct == "carol")
        #expect(entries.account(withID: "4")?.acct == "dave")
        #expect(entries.account(withID: "5") == nil)
    }

    /// 通知の対象の投稿の人、人のリストの人からも探す。
    @Test func accountIsFoundInNotificationTargetsAndAccountEntries() {
        let target = status(account: account("6", "erin"), reblog: status(account: account("7", "frank")))
        let entries: [TimelineEntry] = [.notification(notification(.favourite, from: account("4", "dave"), status: target)), .account(account("8", "grace"))]

        #expect(entries.account(withID: "6")?.acct == "erin")
        #expect(entries.account(withID: "7")?.acct == "frank")
        #expect(entries.account(withID: "8")?.acct == "grace")
    }

    /// 本文のメンションのリンクにはIDがないため、タイムラインの投稿のメンションからリンク先で引く。ブーストされた投稿と、通知の対象の投稿からも探す。
    @Test func mentionIsFoundByURL() throws {
        let carol = Mention(id: "3", username: "carol", url: URL(string: "https://example.social/@carol"), acct: "carol")
        let dave = Mention(id: "4", username: "dave", url: URL(string: "https://remote.example/@dave"), acct: "dave@remote.example")
        let boost = status(reblog: status(mentions: [carol]))
        let entries: [TimelineEntry] = [.status(boost), .notification(notification(.mention, from: account("2", "bob"), status: status(mentions: [dave])))]

        #expect(entries.mention(withURL: try #require(URL(string: "https://example.social/@carol")))?.id == "3")
        #expect(entries.mention(withURL: try #require(URL(string: "https://remote.example/@dave")))?.id == "4")
        #expect(entries.mention(withURL: try #require(URL(string: "https://example.social/@erin"))) == nil)
    }
}
