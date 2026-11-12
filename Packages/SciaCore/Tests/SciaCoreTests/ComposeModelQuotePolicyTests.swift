import Foundation
@testable import SciaCore
import SciaTesting
import Testing

/// 投稿欄の引用できる人。決まりはdocs/quote.mdの「引用できる人を決める」にある。
@MainActor
struct ComposeModelQuotePolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeModel(defaultQuotePolicy: QuotePolicy?? = .some(.public), post: @escaping (StatusDraft) async throws -> Void = { _ in }) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", post: post)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultQuotePolicy: defaultQuotePolicy)
        return model
    }

    private func status(visibility: Status.Visibility = .public, automatic: [String]?) -> Status {
        Status(
            id: "10",
            createdAt: Self.now,
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: URL(string: "https://example.social/a.png")),
            content: "<p>hello</p>",
            spoilerText: "",
            url: nil,
            visibility: visibility,
            quoteApproval: automatic.map { QuoteApproval(automatic: $0, currentUser: "automatic") }
        )
    }

    /// 書き始めたときはアカウントの既定にし、既定のままならバッジを見せない。
    @Test func startsWithDefault() async {
        var sent: [StatusDraft] = []
        let model = makeModel(defaultQuotePolicy: .some(.followers)) { sent.append($0) }
        model.text = "おはよう"

        #expect(model.shownQuotePolicy == .followers)
        #expect(!model.choosesNonDefaultQuotePolicy)
        await model.submit()
        #expect(sent.map(\.sentQuotePolicy) == [.followers])
    }

    /// 引用に対応していないサーバーでは、選ばせず、送らない。
    @Test func unsupportedServerSendsNothing() async {
        var sent: [StatusDraft] = []
        let model = makeModel(defaultQuotePolicy: .some(nil)) { sent.append($0) }
        model.text = "おはよう"

        model.choose(quotePolicy: .nobody)
        await model.submit()

        #expect(model.shownQuotePolicy == nil)
        #expect(!model.canChooseQuotePolicy)
        #expect(sent.map(\.sentQuotePolicy) == [nil])
    }

    /// 選んだ値で送り、送れたら次の投稿は既定に戻す。
    @Test func chosenPolicyIsResetAfterPosting() async {
        var sent: [StatusDraft] = []
        let model = makeModel { sent.append($0) }
        model.text = "hello"

        model.choose(quotePolicy: .nobody)
        #expect(model.choosesNonDefaultQuotePolicy)
        #expect(model.canDiscardDraft)
        await model.submit()

        #expect(sent.map(\.sentQuotePolicy) == [.nobody])
        #expect(model.quotePolicy == .public)
        #expect(!model.choosesNonDefaultQuotePolicy)
    }

    /// 選んだあとに既定が届いても、選んだ値を上書きしない。選んでいなければ、届いた既定に替える。
    @Test func defaultArrivingLaterKeepsChosenPolicy() {
        let model = makeModel()

        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultQuotePolicy: .some(.followers))
        #expect(model.quotePolicy == .followers)

        model.choose(quotePolicy: .nobody)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultQuotePolicy: .some(.public))
        #expect(model.quotePolicy == .nobody)
        #expect(model.defaultQuotePolicy == .public)
    }

    /// フォロワーのみとメンションした相手のみの間は「自分のみ」に決まり、選べず、バッジも見せない。公開範囲を戻すと、選んでいた値に戻る。
    @Test func narrowVisibilityFixesPolicyAndRemembersChoice() async {
        var sent: [StatusDraft] = []
        let model = makeModel { sent.append($0) }
        model.text = "hello"
        model.choose(quotePolicy: .followers)

        model.choose(.private)
        #expect(model.shownQuotePolicy == .nobody)
        #expect(!model.canChooseQuotePolicy)
        #expect(!model.choosesNonDefaultQuotePolicy)
        #expect(model.quotePolicyFixedReason != nil)
        model.choose(quotePolicy: .public)
        #expect(model.quotePolicy == .followers)

        model.choose(.public)
        #expect(model.shownQuotePolicy == .followers)
        #expect(model.quotePolicyFixedReason == nil)

        model.choose(.direct)
        await model.submit()
        #expect(sent.map(\.sentQuotePolicy) == [.nobody])
    }

    /// 編集と削除して書き直すでは、元の投稿の値を戻し、既定が届いても上書きしない。
    @Test func editingAndRedraftingRestorePolicy() throws {
        let source = StatusSource(id: "10", text: "hello", spoilerText: "")
        let editing = makeModel()
        #expect(editing.beginEditing(status(automatic: ["followers"]), source: source, now: Self.now))
        #expect(editing.quotePolicy == .followers)
        #expect(editing.choosesNonDefaultQuotePolicy)
        editing.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultQuotePolicy: .some(.public))
        #expect(editing.quotePolicy == .followers)

        let redrafting = makeModel()
        #expect(redrafting.beginRedrafting(status(automatic: []), source: source))
        #expect(redrafting.quotePolicy == .nobody)

        // 引用に対応していないサーバーの投稿は値がなく、送らない。
        let unsupported = makeModel(defaultQuotePolicy: .some(nil))
        #expect(unsupported.beginEditing(status(automatic: nil), source: source, now: Self.now))
        #expect(unsupported.quotePolicy == nil)
    }

    /// 予約の書き直しでは、予約したときの値を戻す。値を送っていない予約は、既定にする。
    @Test func rewritingScheduleRestoresPolicy() {
        func scheduled(_ policy: QuotePolicy?) -> ScheduledStatus {
            ScheduledStatus(id: "1", scheduledAt: Self.now.addingTimeInterval(3_600), params: .init(text: "hello", quotePolicy: policy), mediaAttachments: [])
        }
        let model = makeModel(defaultQuotePolicy: .some(.followers))

        #expect(model.beginRewriting(scheduled(.nobody)))
        #expect(model.quotePolicy == .nobody)

        #expect(model.beginRewriting(scheduled(nil)))
        #expect(model.quotePolicy == .followers)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultQuotePolicy: .some(.public))
        #expect(model.quotePolicy == .public)
    }

    /// 引用できる人を選んでから、引用に対応していないサーバーのアカウントに替え、対応しているアカウントへ戻したら、また選べる。
    @Test func returningToSupportingAccountOffersPolicyAgain() {
        let model = makeModel()
        model.choose(quotePolicy: .nobody)
        let unsupported = ComposeAccount<Never>(id: "other", myAccountID: "2", media: .unavailable, post: { _ in })

        #expect(model.switchAccount(to: unsupported))
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: false, defaultQuotePolicy: .some(nil), accountID: "other")
        #expect(model.quotePolicy == nil)

        #expect(model.switchAccount(to: nil))
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: false, defaultQuotePolicy: .some(.followers))
        #expect(model.quotePolicy == .followers)
        #expect(model.canChooseQuotePolicy)
    }
}
