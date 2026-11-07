#if DEBUG
import SciaCore
import SwiftUI
import UIKit

/// ユーザーのメニューの「リストに追加」のシート。サーバーに送らずに、読み込み中や失敗、長い名前、リストがないとき、足せない相手、フォローしている途中を並べる。
/// リストを押しても何も送らない。
enum ListMembershipCatalog {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "サーバーに接続できませんでした。" }
    }

    @MainActor
    static func states() -> [CatalogState] {
        [
            state("入っているリストと入っていないリスト（長い名前）"),
            state("読み込み中", lists: { try await Task.sleep(for: .seconds(3_600)); return [] }),
            state("読めなかった", lists: { throw Failure() }),
            state("リストがない", lists: { [] }),
            state("ブロックしていて足せない", relationship: Relationship(id: "2", following: true, blocking: true)),
            state("フォローしている途中", relationship: Relationship(id: "2")) { model in
                model.followAndAdd("1")
            },
        ]
    }

    private static let lists = [
        MastodonList(id: "1", title: "友だち"),
        MastodonList(id: "2", title: "とても長い名前のリストで、シートの幅に入りきらないときにどこで折り返すかを確かめるためのもの"),
        MastodonList(id: "3", title: "仕事"),
    ]

    @MainActor
    private static func state(
        _ title: String,
        lists: @escaping @Sendable () async throws -> [MastodonList] = { ListMembershipCatalog.lists },
        relationship: Relationship = Relationship(id: "2", following: true),
        after: @escaping @MainActor (ListMembershipModel) -> Void = { _ in }
    ) -> CatalogState {
        CatalogState(title: title) {
            let model = ListMembershipModel(isMyself: false, api: ListMembershipModel.API(
                lists: lists,
                listsContaining: { [ListMembershipCatalog.lists[1]] },
                relationship: { relationship },
                add: { _ in },
                remove: { _ in },
                follow: { try await Task.sleep(for: .seconds(3_600)); return relationship },
                create: { MastodonList(id: "9", title: $0) }
            ), tasks: TaskScope())
            let task = model.load()
            Task(.withoutRequests) {
                await task?.value
                after(model)
            }
            let controller = UIHostingController(rootView: ListMembershipView(model: model, acct: "bob@remote.example", requestCreate: { _ in }, dismiss: {}))
            return CatalogControllerHost(controller, height: 420)
        }
    }
}
#endif
