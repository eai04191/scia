import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// テストから`TimelineStore`を操作する入り口。中のストアには`expectChanges`の中でしか触れないので、起きる変化を書かずに状態を変えるテストを書けない。
/// テストで`TimelineStore`を直接作ったり持ったりするのは、`make lint`の`timeline_store_without_tester`で止める。
/// 状態から作る値（並べる投稿、ギャップ、未読の数など）は、変化を書かずに読める。
@MainActor
final class TimelineStoreTester {
    private let store: TimelineStore

    /// `now`を渡さなければ、`TimelineStore`の既定の今の時刻を使う。
    init(pageSize: Int, filtering: StatusFiltering? = nil, now: (@MainActor () -> Date)? = nil, fetch: @escaping TimelineStore.Fetch) {
        store = if let now {
            TimelineStore(pageSize: pageSize, filtering: filtering, now: now, fetch: fetch)
        } else {
            TimelineStore(pageSize: pageSize, filtering: filtering, fetch: fetch)
        }
    }

    /// `operation`にストアを渡して走らせ、前の状態に`change`を当てたものと、後の状態を比べる。`SciaTesting.expectChanges`を参照。
    @discardableResult
    func expectChanges<Value>(
        during operation: (TimelineStore) async throws -> Value,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ change: (inout TimelineStore.State) throws -> Void
    ) async throws -> Value {
        try await SciaTesting.expectChanges(of: { store.state }, during: { try await operation(store) }, sourceLocation: sourceLocation, change)
    }

    // MARK: - 状態と、状態から作る値

    var state: TimelineStore.State { store.state }
    var entries: [TimelineEntry] { store.entries }
    var statuses: [Status] { store.statuses }
    var pending: [Status] { store.pending }
    var gaps: [TimelineGap] { store.gaps }
    var gapFailures: [String: ErrorPresentation] { store.gapFailures }
    var isEmpty: Bool { store.isEmpty }
    var reachedEnd: Bool { store.reachedEnd }
    var isLoading: Bool { store.isLoading }
    var isRegenerating: Bool { store.isRegenerating }
    var lastReadID: String? { store.lastReadID }
    var savedReadID: String? { store.savedReadID }
    var loadingGapIDs: Set<String> { store.loadingGapIDs }
    var unreadCount: Int { store.unreadCount }
    var hasUnloadedUnread: Bool { store.hasUnloadedUnread }
    var readIDToSave: String? { store.readIDToSave }
}
