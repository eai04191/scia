import SciaCore
import SwiftUI
import UIKit

/// フィルターの画面。サーバーのフィルターを変えずに、読み込み中や失敗、空、長い名前とキーワード、期限のあるものと切れたもの、保存や削除をサーバーが断ったとき、保存に時間がかかるときを並べる。
/// 項目を押すと編集の画面が開く。保存と削除は通信せず、断る状態のほかは受け付けたことにする。
enum FiltersCatalog {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "サーバーに接続できませんでした。" }
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let filters = [
        ServerFilter(id: "1", title: "ネタバレ", context: [.home, .public], filterAction: .warn, keywords: [ServerFilter.Keyword(id: "10", keyword: "最終回", wholeWord: false)]),
        ServerFilter(
            id: "2", title: String(repeating: "とても長いフィルターの名前", count: 4), context: [.home], filterAction: .hide, expiresAt: now.addingTimeInterval(86_400),
            keywords: (0..<12).map { ServerFilter.Keyword(id: "2\($0)", keyword: "長いキーワードの並び\($0)", wholeWord: true) }
        ),
        ServerFilter(id: "3", title: "#scia", context: [.home, .notifications, .public, .thread, .account], filterAction: .hide, expiresAt: now.addingTimeInterval(-60), keywords: [ServerFilter.Keyword(id: "30", keyword: "#scia", wholeWord: true)]),
        ServerFilter(id: "4", title: "キーワードのないフィルター", context: [.account], filterAction: .blur, keywords: [], statuses: [ServerFilter.FilteredStatus(id: "40", statusId: "1"), ServerFilter.FilteredStatus(id: "41", statusId: "2")]),
        ServerFilter(id: "5", title: "このアプリが知らない扱いと対象", context: [.other("lists")], filterAction: .other("quarantine"), keywords: [ServerFilter.Keyword(id: "50", keyword: "word", wholeWord: true)]),
    ]

    @MainActor
    static func states() -> [CatalogState] {
        [
            state("読み込み中") { try await Task.sleep(for: .seconds(3_600)); return [] },
            state("読めなかった") { throw Failure() },
            state("フィルターがない") { [] },
            state("長い名前、期限、期限切れ、キーワードなし、知らない扱い") { filters },
            state("保存と削除をサーバーが断る", accepts: false) { filters },
            state("保存に時間がかかる（送っている間は編集もキャンセルも削除もできない）", saveDelay: .seconds(3_600)) { filters },
        ]
    }

    @MainActor
    private static func state(_ title: String, accepts: Bool = true, saveDelay: Duration? = nil, load: @escaping @Sendable () async throws -> [ServerFilter]) -> CatalogState {
        CatalogState(title: title) {
            let refused = MastodonAPIError(statusCode: 422, message: "Validation failed", serverMessage: "Validation failed: Title is too long (maximum is 256 characters)")
            let api = FiltersModel.API(load: load) { draft in
                guard accepts else { throw refused }
                if let saveDelay {
                    try await Task.sleep(for: saveDelay)
                }
                return ServerFilter(id: draft.original?.id ?? "new", title: draft.trimmedTitle, context: draft.orderedContexts, filterAction: draft.action, keywords: [])
            } delete: { _ in
                guard accepts else { throw refused }
            }
            let controller = UIHostingController(rootView: FiltersView(model: FiltersModel(api: api, tasks: TaskScope()), now: { now }))
            return CatalogControllerHost(controller, height: 640)
        }
    }
}
