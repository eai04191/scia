import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct AccountListStoreTests {
    /// 呼ばれた`max_id`を記録し、登録した順にページを返す。
    private final class PageQueue: Sendable {
        private let state: Mutex<(pages: [AccountListPage], maxIDs: [String?])>

        init(_ pages: [AccountListPage]) {
            state = Mutex((pages, []))
        }

        func next(_ maxID: String?) -> AccountListPage {
            state.withLock { state in
                state.maxIDs.append(maxID)
                guard !state.pages.isEmpty else {
                    Issue.record("想定より多く読み込まれました")
                    return AccountListPage(accounts: [], nextMaxID: nil)
                }
                return state.pages.removeFirst()
            }
        }

        var maxIDs: [String?] { state.withLock { $0.maxIDs } }
    }

    private func accounts(_ ids: [String]) -> [Account] {
        ids.map { Account(id: $0, username: "user\($0)", acct: "user\($0)", displayName: "", avatar: nil) }
    }

    private func makeStore(_ queue: PageQueue) -> AccountListStore {
        AccountListStore(kind: .favouritedBy("1")) { maxID in queue.next(maxID) }
    }

    @Test func readsPagesFromTheLinkHeaderUntilThereIsNoNext() async throws {
        let queue = PageQueue([
            AccountListPage(accounts: accounts(["5", "6"]), nextMaxID: "100"),
            AccountListPage(accounts: accounts(["7"]), nextMaxID: nil),
        ])
        let store = makeStore(queue)

        #expect(try await store.loadInitial()?.map(\.id) == ["5", "6"])
        #expect(!store.reachedEnd)
        #expect(try await store.loadOlder()?.map(\.id) == ["7"])

        #expect(store.accounts.map(\.id) == ["5", "6", "7"])
        #expect(store.reachedEnd)
        #expect(queue.maxIDs == [nil, "100"])
        #expect(try await store.loadOlder() == nil)
    }

    /// 同じ人は1度だけ並べ、同じ位置を返し続けるサーバーでは、そこで終わりにする。
    @Test func dropsDuplicatesAndStopsWhenThePositionDoesNotAdvance() async throws {
        let queue = PageQueue([
            AccountListPage(accounts: accounts(["5", "6"]), nextMaxID: "100"),
            AccountListPage(accounts: accounts(["6", "7"]), nextMaxID: "100"),
        ])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(try await store.loadOlder()?.map(\.id) == ["7"])
        #expect(store.reachedEnd)
    }

    /// リストのメンバーの画面で足した人は先頭に出し、もう並んでいる人は重ねない。外した人は除く。
    @Test func prependAndRemoveChangeTheList() async throws {
        let store = makeStore(PageQueue([AccountListPage(accounts: accounts(["5", "6"]), nextMaxID: nil)]))
        _ = try await store.loadInitial()

        store.prepend(accounts(["7"])[0])
        store.prepend(accounts(["6"])[0])
        #expect(store.accounts.map(\.id) == ["7", "5", "6"])

        store.remove(accountID: "5")
        #expect(store.accounts.map(\.id) == ["7", "6"])
    }

    /// 読み直している間に外したり足したりした人は、その前に送り出した読み直しの応答で戻さない。
    @Test func changesDuringReloadSurviveTheOlderResponse() async throws {
        let gate = Gate()
        let store = AccountListStore(kind: .listMembers(listID: "1")) { _ in
            try await gate.wait()
            return AccountListPage(accounts: [Account(id: "5", username: "user5", acct: "user5", displayName: "", avatar: nil)], nextMaxID: nil)
        }
        let reload = Task { try await store.loadInitial() }
        try await waitUntil { gate.waiterCount == 1 }
        store.remove(accountID: "5")
        store.prepend(accounts(["7"])[0])
        gate.open()
        _ = try await reload.value

        #expect(store.accounts.map(\.id) == ["7"])
    }

    /// 読み込み直すと、最初のページで置き換える。
    @Test func loadInitialReplacesTheList() async throws {
        let queue = PageQueue([
            AccountListPage(accounts: accounts(["5", "6"]), nextMaxID: "100"),
            AccountListPage(accounts: accounts(["8"]), nextMaxID: nil),
        ])
        let store = makeStore(queue)
        _ = try await store.loadInitial()
        _ = try await store.loadInitial()

        #expect(store.accounts.map(\.id) == ["8"])
        #expect(store.reachedEnd)
    }
}
