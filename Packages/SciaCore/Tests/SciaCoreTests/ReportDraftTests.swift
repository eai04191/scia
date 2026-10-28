import Foundation
import Testing
@testable import SciaCore

@MainActor
struct ReportDraftTests {
    private struct Failure: Error {}

    private actor Submissions {
        private(set) var requests: [ReportRequest] = []

        func append(_ request: ReportRequest) {
            requests.append(request)
        }
    }

    private func draft(acct: String = "bob", statusID: String? = nil, rules: [InstanceRule] = [], failsRules: Bool = false, submitted: Submissions = Submissions(), failsSubmit: Bool = false) -> ReportDraft {
        ReportDraft(accountID: "2", acct: acct, statusID: statusID, api: ReportDraft.API(
            rules: {
                if failsRules { throw Failure() }
                return rules
            },
            submit: { request in
                if failsSubmit { throw Failure() }
                await submitted.append(request)
            }
        ))
    }

    /// 理由の種類を選ぶまで送れない。ルールへの違反は、ルールを1つ以上選ぶまで送れない。
    @Test func requiresCategoryAndRulesForViolation() {
        let report = draft()
        #expect(!report.canSubmit)

        report.category = ReportCategory.violation
        #expect(!report.canSubmit)

        report.toggleRule("1")
        #expect(report.canSubmit)
        report.toggleRule("1")
        #expect(!report.canSubmit)
    }

    /// コメントの長さでは止めない。Mastodonの既定の上限（1000文字）を超えても送れる。
    @Test func longCommentCanBeSubmitted() {
        let report = draft()
        report.category = ReportCategory.other
        report.comment = String(repeating: "あ", count: 5_000)
        #expect(report.canSubmit)
        #expect(report.request?.comment == report.comment)
    }

    /// 文字数は、サーバーと同じくコードポイントで数える。結合文字の絵文字は、見た目の1文字でも複数に数える。
    @Test func commentLengthCountsCodePoints() {
        let report = draft()
        report.comment = "あ👍🏽"
        #expect(report.commentLength == 3)
    }

    /// サーバーが長さなどで断ったら、返した理由を送れなかった理由として出す。
    @Test func rejectionShowsServerReason() async {
        let reason = "Validation failed: Comment is too long (maximum is 1000 characters)"
        let report = ReportDraft(accountID: "2", acct: "bob", statusID: nil, api: ReportDraft.API(
            rules: { [] },
            submit: { _ in throw MastodonAPIError.from(statusCode: 422, body: Data(#"{"error":"\#(reason)"}"#.utf8)) }
        ))
        report.category = ReportCategory.other
        report.comment = String(repeating: "あ", count: 1_001)

        #expect(await report.submit() == false)
        #expect(report.submitError.map { ErrorPresentation($0).message } == reason)
        #expect(report.canSubmit)
    }

    /// 添える投稿と転送は、外したら送らない。転送は、ほかのサーバーのアカウントでだけ送る。ルールは、違反を選んだときだけ送る。
    @Test func requestFollowsChoices() {
        let remote = draft(acct: "bob@remote.example", statusID: "100")
        remote.category = ReportCategory.violation
        remote.toggleRule("2")
        remote.toggleRule("1")
        remote.forward = true
        remote.comment = "迷惑"
        #expect(remote.remoteDomain == "remote.example")
        #expect(remote.request == ReportRequest(accountID: "2", statusIDs: ["100"], comment: "迷惑", forward: true, category: .violation, ruleIDs: ["1", "2"]))

        remote.includesStatus = false
        remote.category = ReportCategory.spam
        #expect(remote.request == ReportRequest(accountID: "2", comment: "迷惑", forward: true, category: .spam))

        let local = draft()
        local.category = ReportCategory.other
        local.forward = true
        #expect(local.remoteDomain == nil)
        #expect(local.request?.forward == false)
    }

    /// 送れなければ、書いた内容を残して理由を出し、もう一度送れる。
    @Test func failedSubmitKeepsDraft() async {
        let report = draft(failsSubmit: true)
        report.category = ReportCategory.other
        report.comment = "理由"

        #expect(await report.submit() == false)
        #expect(report.submitError != nil)
        #expect(report.comment == "理由")
        #expect(report.canSubmit)
    }

    @Test func submitSendsRequest() async {
        let submitted = Submissions()
        let report = draft(submitted: submitted)
        report.category = ReportCategory.legal

        #expect(await report.submit())
        #expect(await submitted.requests == [ReportRequest(accountID: "2", category: .legal)])
    }

    /// ルールを読めなければ、読めなかったことを出し、読み直せる。
    @Test func rulesCanBeReloadedAfterFailure() async {
        let failing = draft(failsRules: true)
        await failing.loadRules()
        guard case .failed = failing.rules else {
            Issue.record("読めなかった状態になっていません")
            return
        }

        let rules = [InstanceRule(id: "1", text: "スパム禁止")]
        let loaded = draft(rules: rules)
        await loaded.loadRules()
        guard case .loaded(let got) = loaded.rules else {
            Issue.record("読めた状態になっていません")
            return
        }
        #expect(got == rules)
    }
}
