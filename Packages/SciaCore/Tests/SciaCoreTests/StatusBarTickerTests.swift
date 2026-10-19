import Foundation
import Testing
@testable import SciaCore

struct StatusBarTickerItemTests {
    private let actor = Account(id: "2", username: "bob", acct: "bob@example.social", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(content: String, spoilerText: String = "", mentions: [Mention] = [], attachments: [MediaAttachment] = [], sensitive: Bool = false) -> Status {
        Status(
            id: "10",
            createdAt: Date(timeIntervalSince1970: 0),
            account: actor,
            content: content,
            spoilerText: spoilerText,
            url: nil,
            mentions: mentions,
            mediaAttachments: attachments,
            sensitive: sensitive
        )
    }

    private func notification(_ type: MastodonNotification.Kind, status: Status? = nil) -> MastodonNotification {
        MastodonNotification(id: "1", type: type, createdAt: Date(timeIntervalSince1970: 0), account: actor, status: status)
    }

    private func image(_ id: String) -> MediaAttachment {
        MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/\(id).png"), previewUrl: URL(string: "https://example.social/\(id)-small.png"))
    }

    private func video(_ id: String) -> MediaAttachment {
        MediaAttachment(id: id, type: .video, url: URL(string: "https://example.social/\(id).mp4"), previewUrl: URL(string: "https://example.social/\(id)-small.png"))
    }

    private func text(of item: StatusBarTickerItem?) -> String? {
        guard case .text(let text) = item?.subject else { return nil }
        return text.plainText
    }

    @Test func joinsParagraphsAndLineBreaksIntoOneLine() {
        let item = StatusBarTickerItem(notification(.favourite, status: status(content: "<p>一行目<br>二行目</p><p>次の段落</p>")))

        #expect(text(of: item) == "一行目 二行目 次の段落")
    }

    @Test func dropsLeadingMentionsOfReply() {
        // 照合に使うのはacctだけなので、URLはどれでもよい。
        let me = Mention(id: "1", username: "me", url: URL(filePath: "/@me"), acct: "me")
        let content = #"<p><span class="h-card"><a href="https://example.social/@me" class="u-url mention">@<span>me</span></a></span> ありがとう</p>"#

        let item = StatusBarTickerItem(notification(.mention, status: status(content: content, mentions: [me])))

        #expect(text(of: item) == "ありがとう")
    }

    @Test func showsSpoilerInsteadOfBody() {
        let item = StatusBarTickerItem(notification(.reblog, status: status(content: "<p>中身</p>", spoilerText: "ネタバレ")))

        #expect(text(of: item) == "ネタバレ")
    }

    @Test func showsFirstAttachmentWhenPostHasNoText() {
        let item = StatusBarTickerItem(notification(.favourite, status: status(content: "", attachments: [image("a"), image("b")], sensitive: true)))

        #expect(item?.subject == .media(image("a"), isSensitive: true, isImageOnly: true))
    }

    @Test func tellsWhenPostAlsoHasNonImageMedia() {
        // 読み上げで、動画やGIFを含む投稿を「画像だけの投稿」と言わないため。
        let item = StatusBarTickerItem(notification(.favourite, status: status(content: "", attachments: [image("a"), video("b")])))

        #expect(item?.subject == .media(image("a"), isSensitive: false, isImageOnly: false))
    }

    @Test func prefersTextOverAttachments() {
        let item = StatusBarTickerItem(notification(.favourite, status: status(content: "<p>写真</p>", attachments: [image("a")])))

        #expect(text(of: item) == "写真")
    }

    @Test func showsFilterTitleInsteadOfBodyWhenWarned() {
        let verdict = FilterVerdict(isHidden: false, warningTitles: ["ネタバレ", "政治"], mediaTitles: [], ownMatchTitles: [])

        let item = StatusBarTickerItem(notification(.mention, status: status(content: "<p>犯人はヤス</p>")), verdict: verdict)

        // 通知の一覧と同じく、本文を見せずにフィルターの名前だけを出す。
        #expect(text(of: item) == "フィルター「ネタバレ」「政治」に一致")
    }

    @Test func coversAttachmentWhenBlurred() {
        let verdict = FilterVerdict(isHidden: false, warningTitles: [], mediaTitles: ["写真"], ownMatchTitles: [])

        let item = StatusBarTickerItem(notification(.mention, status: status(content: "", attachments: [image("a")])), verdict: verdict)

        #expect(item?.subject == .media(image("a"), isSensitive: true, isImageOnly: true))
    }

    @Test func showsHandleWhenThereIsNoPost() {
        let item = StatusBarTickerItem(notification(.follow))

        #expect(item?.subject == .handle("@bob@example.social"))
    }

    @Test func skipsUnknownKinds() {
        #expect(StatusBarTickerItem(notification(.other("admin.sign_up"))) == nil)
    }
}

struct StatusBarTickerQueueTests {
    private let timing = StatusBarTickerQueue<Int>.Timing(duration: 3, minimumDuration: 1, shrink: 0.5, capacity: 3)

    @Test func shortensDurationWhileNotificationsAreWaiting() {
        var queue = StatusBarTickerQueue<Int>(timing: timing)
        #expect(queue.displayDuration == 3)

        queue.enqueue(1)
        #expect(queue.displayDuration == 1.5)

        queue.enqueue(2)
        // 3 × 0.25 = 0.75は下限より短いため、下限で止める。
        #expect(queue.displayDuration == 1)
    }

    @Test func dropsOldestBeyondCapacity() {
        var queue = StatusBarTickerQueue<Int>(timing: timing)
        for value in 1...5 {
            queue.enqueue(value)
        }

        #expect(queue.waiting == [3, 4, 5])
        #expect(queue.next() == 3)
        #expect(queue.waiting == [4, 5])
    }
}
