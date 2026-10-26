import Foundation
import Testing
@testable import SciaCore

/// 引用して投稿するときの決まりを確かめる。決まりは`docs/quote.md`の「引用して投稿する」。
struct QuotePostingTests {
    private let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(_ id: String, visibility: Status.Visibility = .public, quoteApproval: QuoteApproval? = nil, reblog: Status? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: bob, content: "<p>本文</p>", spoilerText: "", url: nil, visibility: visibility, quoteApproval: quoteApproval, reblog: reblog)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func canPost(_ draft: StatusDraft) -> Bool {
        draft.canPost(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4)
    }

    /// 自分の操作を表す項目（`favourited`など）を足して、ログインした人向けの形にする。
    private func renderedForViewer(_ data: Data) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["favourited"] = false
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func decodesQuoteApproval() throws {
        let status = try MastodonDecoder.make().decode(Status.self, from: try renderedForViewer(try fixture("status_with_quote")))
        let approval = try #require(status.quoteApproval)

        #expect(approval.automatic == ["followers"])
        #expect(approval.manual.isEmpty)
        #expect(approval.currentUser == "denied")
        #expect(approval.availability == .denied(followersOnly: true))
        // 引用元の投稿には付いていないので、引用に対応していないサーバーと同じくnilになる。
        #expect(status.quote?.quotedStatus?.quoteApproval == nil)
    }

    /// 公開とハッシュタグのストリーミングは、ログインしていない人向けの形（自分の操作を表す項目がない）で届き、`current_user`がいつも`denied`になる。
    /// そのときは押せるようにし、押してから確かめる。
    @Test func anonymousPayloadLeavesAvailabilityUnverified() throws {
        let anonymous = try MastodonDecoder.make().decode(Status.self, from: try fixture("status_with_quote"))

        #expect(anonymous.quoteApproval?.currentUser == "denied")
        #expect(anonymous.quoteApproval?.availability == .unverified)
        #expect(anonymous.quoteApproval?.availability.canQuote == true)
    }

    @Test func availabilityFollowsCurrentUser() {
        #expect(QuoteApproval(automatic: ["public"], currentUser: "automatic").availability == .automatic)
        #expect(QuoteApproval(manual: ["public"], currentUser: "manual").availability == .manual)
        #expect(QuoteApproval(automatic: ["followers"], currentUser: "denied").availability == .denied(followersOnly: true))
        #expect(QuoteApproval(manual: ["followers"], currentUser: "denied").availability == .denied(followersOnly: true))
        #expect(QuoteApproval(currentUser: "denied").availability == .denied(followersOnly: false))
    }

    /// `unknown`と知らない値は、引用できないものとして扱う。
    @Test func treatsUnknownCurrentUserAsDenied() {
        #expect(QuoteApproval(automatic: ["unsupported_policy"], currentUser: "unknown").availability == .denied(followersOnly: false))
        #expect(QuoteApproval(automatic: ["public"], currentUser: "someday").availability == .denied(followersOnly: false))
        #expect(!QuoteApproval(currentUser: "unknown").availability.canQuote)
    }

    /// ブーストは元の投稿を引用する。宛先と注意書きは入れない。
    @Test func quoteDraftTargetsDisplayedStatus() {
        let boost = status("20", reblog: status("10"))

        let draft = StatusDraft.quote(of: boost)

        #expect(draft.quotedStatusID == "10")
        #expect(draft.inReplyToID == nil)
        #expect(draft.text.isEmpty)
        #expect(draft.spoilerText.isEmpty)
    }

    /// 返信と同じく、引用元と既定のうち狭い方にする。フォロワー限定より狭い引用元は、選べる上限のフォロワー限定までにする。
    @Test func quoteDraftNarrowsVisibilityToQuotedStatus() {
        #expect(StatusDraft.quote(of: status("1", visibility: .public), defaultVisibility: .public).visibility == .public)
        #expect(StatusDraft.quote(of: status("1", visibility: .public), defaultVisibility: .unlisted).visibility == .unlisted)
        #expect(StatusDraft.quote(of: status("1", visibility: .unlisted), defaultVisibility: .public).visibility == .unlisted)
        #expect(StatusDraft.quote(of: status("1", visibility: .other("limited")), defaultVisibility: .public).visibility == .private)
        #expect(StatusDraft.quote(of: status("1", visibility: .private), defaultVisibility: .public).visibility == .private)
        #expect(StatusDraft.quote(of: status("1", visibility: .private), defaultVisibility: .direct).visibility == .direct)
        #expect(StatusDraft.maxVisibility(quoting: status("1", visibility: .unlisted)) == nil)
        #expect(StatusDraft.maxVisibility(quoting: status("1", visibility: .private)) == .private)
        #expect(StatusDraft.maxVisibility(quoting: status("1", visibility: .other("limited"))) == .private)
    }

    /// Mastodonは引用と添付・投票を一緒に付けられない。
    @Test func cannotPostQuoteWithAttachmentsOrPoll() {
        let media = DraftAttachment(state: .uploaded(MediaAttachment(id: "100", type: .image, url: URL(string: "https://example.social/100.png"), previewUrl: nil)))
        let poll = PollDraft(options: ["朝", "夜"], expiresIn: 3_600)

        #expect(canPost(StatusDraft(text: "見て", quotedStatusID: "1")))
        #expect(!canPost(StatusDraft(text: "見て", quotedStatusID: "1", attachments: [media])))
        #expect(!canPost(StatusDraft(text: "見て", quotedStatusID: "1", poll: poll)))
    }

    /// Mastodonは引用のある投稿で本文を求めない（`Status`の`validates :text, presence: true, unless: ... with_quote?`）。
    @Test func canPostQuoteWithoutText() {
        #expect(canPost(StatusDraft(text: " ", quotedStatusID: "1")))
        #expect(canPost(StatusDraft(spoilerText: "注意", quotedStatusID: "1")))
    }
}
