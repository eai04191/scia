import Foundation
import Testing
@testable import SciaCore

struct StatusLengthTests {
    private func count(_ text: String, spoiler: String = "") -> Int {
        StatusLength.count(text: text, spoilerText: spoiler, charactersReservedPerURL: 23)
    }

    @Test func countsGraphemeClusters() {
        #expect(count("こんにちは") == 5)
        // 結合された絵文字は1文字として数える。
        #expect(count("👨‍👩‍👧‍👦🇯🇵") == 2)
    }

    @Test func countsSpoilerTogetherWithText() {
        #expect(count("本文", spoiler: "注意") == 4)
    }

    @Test func countsURLAsReservedLength() {
        #expect(count("見て https://example.social/@alice/113000000000000001") == 3 + 23)
        // 文末の句点はURLに含めない。
        #expect(count("https://example.com/a.") == 23 + 1)
    }

    @Test func countsRemoteMentionAsLocalPart() {
        #expect(count("@bob@remote.example こんにちは") == "@bob こんにちは".count)
        #expect(count("@alice やあ") == "@alice やあ".count)
    }

    @Test func ignoresAtSignInsideWordsAndURLs() {
        #expect(count("mail@example.com") == "mail@example.com".count)
        #expect(count("https://example.social/@alice@remote.example") == 23)
    }
}

struct StatusDraftTests {
    private func account(_ id: String, _ acct: String) throws -> Account {
        Account(id: id, username: acct, acct: acct, displayName: "", avatar: URL(string: "https://example.social/a.png"))
    }

    private func mention(_ id: String, _ acct: String) throws -> Mention {
        Mention(id: id, username: acct, url: URL(string: "https://example.social/@\(acct)"), acct: acct)
    }

    @Test func replyAddressesAuthorAndMentionsExceptMe() throws {
        let status = Status(
            id: "10",
            createdAt: .now,
            account: try account("2", "bob@remote.example"),
            content: "",
            spoilerText: "ネタバレ",
            url: nil,
            mentions: [try mention("1", "alice"), try mention("3", "carol"), try mention("2", "bob@remote.example")],
            visibility: .unlisted
        )

        let draft = StatusDraft.reply(to: status, myAccountID: "1")

        #expect(draft.text == "@bob@remote.example @carol ")
        #expect(draft.inReplyToID == "10")
        #expect(draft.visibility == .unlisted)
        #expect(draft.spoilerText == "ネタバレ")
    }

    @Test func replyToBoostTargetsOriginalPost() throws {
        let original = Status(id: "10", createdAt: .now, account: try account("2", "bob"), content: "", spoilerText: "", url: nil, visibility: .private)
        let boost = Status(id: "20", createdAt: .now, account: try account("3", "carol"), content: "", spoilerText: "", url: nil, reblog: original)

        let draft = StatusDraft.reply(to: boost, myAccountID: "1")

        #expect(draft.text == "@bob ")
        #expect(draft.inReplyToID == "10")
        #expect(draft.visibility == .private)
    }

    @Test func replyToOwnPostHasNoRecipientAndServerSpecificVisibilityBecomesPrivate() throws {
        let status = Status(id: "10", createdAt: .now, account: try account("1", "alice"), content: "", spoilerText: "", url: nil, visibility: .other("limited"))

        let draft = StatusDraft.reply(to: status, myAccountID: "1")

        #expect(draft.text.isEmpty)
        #expect(draft.visibility == .private)
    }

    @Test func replyIsNarrowedToDefaultVisibility() throws {
        let status = Status(id: "10", createdAt: .now, account: try account("2", "bob"), content: "", spoilerText: "", url: nil, visibility: .public)

        #expect(StatusDraft.reply(to: status, myAccountID: "1", defaultVisibility: .unlisted).visibility == .unlisted)
        #expect(StatusDraft.reply(to: status, myAccountID: "1", defaultVisibility: .public).visibility == .public)
    }

    @Test func onlyPublicOrOwnFollowersOnlyPostsCanBeBoosted() throws {
        func status(_ visibility: Status.Visibility, by accountID: String) throws -> Status {
            Status(id: "10", createdAt: .now, account: try account(accountID, "x"), content: "", spoilerText: "", url: nil, visibility: visibility)
        }

        #expect(try status(.public, by: "2").canBeReblogged(by: "1"))
        #expect(try status(.unlisted, by: "2").canBeReblogged(by: "1"))
        #expect(try !status(.private, by: "2").canBeReblogged(by: "1"))
        #expect(try status(.private, by: "1").canBeReblogged(by: "1"))
        #expect(try !status(.direct, by: "1").canBeReblogged(by: "1"))
    }

    private func canPost(_ draft: StatusDraft, maxMediaAttachments: Int = 4) -> Bool {
        draft.canPost(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: maxMediaAttachments)
    }

    private func uploaded(_ id: String, description: String? = nil) -> DraftAttachment {
        let attachment = MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/\(id).png"), previewUrl: nil, description: description)
        return DraftAttachment(state: .uploaded(attachment), description: description ?? "")
    }

    @Test func cannotPostBlankOrTooLongText() {
        #expect(!canPost(StatusDraft(text: " \n")))
        #expect(canPost(StatusDraft(text: String(repeating: "あ", count: 500))))
        #expect(!canPost(StatusDraft(text: String(repeating: "あ", count: 501))))
    }

    @Test func canPostMediaWithoutText() {
        #expect(canPost(StatusDraft(text: " \n", attachments: [uploaded("1")])))
    }

    @Test func cannotPostUntilEveryAttachmentIsUploaded() {
        let done = uploaded("1")
        for pending in [
            DraftAttachment(state: .uploading),
            DraftAttachment(state: .processing(serverID: "2")),
            DraftAttachment(state: .failed(serverID: nil)),
            DraftAttachment(state: .failed(serverID: "2")),
        ] {
            let draft = StatusDraft(text: "見て", attachments: [done, pending])
            #expect(!canPost(draft))
            #expect(draft.mediaIDs == nil)
        }
    }

    @Test func cannotPostUntilDescriptionReachesServer() {
        var attachment = uploaded("1", description: "猫")
        #expect(canPost(StatusDraft(attachments: [attachment])))

        attachment.description = "窓辺の猫"
        #expect(attachment.needsDescriptionUpdate)
        #expect(!canPost(StatusDraft(attachments: [attachment])))
    }

    @Test func descriptionWaitsForUpload() {
        // 送るのはアップロードが済んでからなので、済む前は送り待ちに数えない。
        let attachment = DraftAttachment(state: .processing(serverID: "1"), description: "猫")
        #expect(!attachment.needsDescriptionUpdate)
        #expect(!attachment.isReady)
        #expect(attachment.serverID == "1")
    }

    @Test func cannotPostMoreAttachmentsThanServerAllows() {
        let draft = StatusDraft(attachments: ["1", "2", "3", "4", "5"].map { uploaded($0) })
        #expect(!canPost(draft, maxMediaAttachments: 4))
        #expect(canPost(draft, maxMediaAttachments: 5))
    }

    @Test func mediaIDsFollowAttachmentOrder() {
        var draft = StatusDraft(attachments: ["1", "2", "3"].map { uploaded($0) })
        draft.attachments.insert(draft.attachments.removeLast(), at: 0)
        #expect(draft.mediaIDs == ["3", "1", "2"])
    }

    @Test func eachDraftHasItsOwnIdempotencyKey() {
        #expect(StatusDraft().idempotencyKey != StatusDraft().idempotencyKey)
    }
}
