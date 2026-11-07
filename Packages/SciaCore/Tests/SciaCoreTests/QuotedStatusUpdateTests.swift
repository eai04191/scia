import Foundation
import SciaTesting
import Testing
@_spi(FailureDisplay) @testable import SciaCore

/// 引用の囲みから行ったお気に入りやブックマークの結果を、引用元を出している囲みにも反映することを確かめる。
/// 反映しないと、囲みは操作の前の状態のままになり、もう一度行うと取り消しではなく同じ操作をもう一度送る。
@MainActor
struct QuotedStatusUpdateTests {
    private let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)

    private func quoted() -> Status {
        Status(id: "10", createdAt: Date(timeIntervalSince1970: 10), account: bob, content: "quoted", spoilerText: "", url: nil)
    }

    private func quoting(_ quoted: Status, id: String = "20") -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 20), account: bob, content: "outer", spoilerText: "", url: nil, quote: Quote(state: "accepted", quotedStatus: quoted))
    }

    @Test func timelineUpdatesQuotedStatus() async throws {
        let outer = quoting(quoted())
        let store = TimelineStore(pageSize: 20) { _ in TimelinePage(statuses: [outer], isRegenerating: false) }
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(outer)]
            $0.oldestLoadedID = "20"
        }
        let changed = try await expectChanges(of: { store.state }, during: { store.updateStatus("10") { $0.settingBookmarked(true) } }) {
            $0.entries = [.status(quoting(quoted().settingBookmarked(true)))]
        }
        #expect(changed)
        #expect(store.statuses.first?.quote?.quotedStatus?.bookmarked == true)
    }

    /// ブーストした投稿の引用元も反映する。
    @Test func timelineUpdatesQuotedStatusInsideReblog() async throws {
        func reblogging(_ status: Status) -> Status {
            Status(id: "30", createdAt: Date(timeIntervalSince1970: 30), account: bob, content: "", spoilerText: "", url: nil, reblog: status)
        }
        let reblog = reblogging(quoting(quoted()))
        let store = TimelineStore(pageSize: 20) { _ in TimelinePage(statuses: [reblog], isRegenerating: false) }
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(reblog)]
            $0.oldestLoadedID = "30"
        }
        let changed = try await expectChanges(of: { store.state }, during: { store.updateStatus("10") { $0.settingBookmarked(true) } }) {
            $0.entries = [.status(reblogging(quoting(quoted().settingBookmarked(true))))]
        }
        #expect(changed)
        #expect(store.statuses.first?.reblog?.quote?.quotedStatus?.bookmarked == true)
    }

    @Test func threadUpdatesQuotedStatus() {
        let store = ThreadStore(focus: quoting(quoted()))
        #expect(store.updateStatus("10") { $0.settingBookmarked(true) })
        #expect(store.entries.compactMap(\.status).first?.quote?.quotedStatus?.bookmarked == true)
    }
}
