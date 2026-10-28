#if DEBUG
import SciaCore
import SwiftUI
import UIKit

/// 通報のシート。サーバーに通報を送らずに、ルールの読み込み中や失敗、長いルール、長いコメント、送れなかったとき、サーバーが断ったときを並べる。送信を押しても何も送らない。
enum ReportSheetCatalog {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "サーバーに接続できませんでした。" }
    }

    @MainActor
    static func states() -> [CatalogState] {
        [
            state("理由を選ぶ前（投稿を添えられる、ほかのサーバーの相手）", acct: "bob@remote.example", statusID: "100") { _ in },
            state("ルールを読み込み中", rules: { try await Task.sleep(for: .seconds(3_600)); return [] }) { draft in
                draft.category = .violation
            },
            state("ルールを読めなかった", rules: { throw Failure() }) { draft in
                draft.category = .violation
            },
            state("ルールがないサーバー", rules: { [] }) { draft in
                draft.category = .violation
            },
            state("長いルールと説明を選んだ") { draft in
                draft.category = .violation
                draft.toggleRule("2")
            },
            state("長いコメント（とても長いサーバー名）", acct: "bob@a-very-long-server-name-that-wraps-in-the-forward-toggle.example") { draft in
                draft.category = .other
                draft.comment = String(repeating: "長いコメント。", count: 150)
            },
            state("送れなかった", submit: { _ in throw Failure() }) { draft in
                draft.category = .spam
                draft.comment = "宣伝のリンクを繰り返し送ってきます。"
                Task { _ = await draft.submit() }
            },
            state("サーバーが断った", submit: { _ in
                let reason = "Validation failed: Comment is too long (maximum is 1000 characters)"
                throw MastodonAPIError(statusCode: 422, message: reason, serverMessage: reason)
            }) { draft in
                draft.category = .other
                draft.comment = String(repeating: "長いコメント。", count: 150)
                Task { _ = await draft.submit() }
            },
        ]
    }

    private static let rules = [
        InstanceRule(id: "1", text: "スパムや宣伝を繰り返さない"),
        InstanceRule(id: "2", text: "差別、嫌がらせ、暴力をあおる投稿をしない。どこで折り返すかを確かめるための長いルールの文です", hint: "ルールの長い説明です。Mastodon 4.3から、ルールに説明を付けられます。説明も長くなることがあります。"),
        InstanceRule(id: "3", text: "閲覧注意の画像には注意書きを付ける"),
    ]

    @MainActor
    private static func state(
        _ title: String,
        acct: String = "bob",
        statusID: String? = nil,
        rules: @escaping @Sendable () async throws -> [InstanceRule] = { ReportSheetCatalog.rules },
        submit: @escaping @Sendable (ReportRequest) async throws -> Void = { _ in },
        fill: @escaping @MainActor (ReportDraft) -> Void
    ) -> CatalogState {
        CatalogState(title: title) {
            let draft = ReportDraft(accountID: "2", acct: acct, statusID: statusID, api: ReportDraft.API(rules: rules, submit: submit))
            fill(draft)
            let controller = UIHostingController(rootView: ReportView(draft: draft) {})
            return CatalogControllerHost(controller, height: 640)
        }
    }
}
#endif
