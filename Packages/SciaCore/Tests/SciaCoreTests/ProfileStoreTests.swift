import Foundation
import Testing
@testable import SciaCore

@MainActor
struct ProfileStoreTests {
    /// 呼ばれた絞り込みを記録する。
    private actor Calls {
        var filters: [AccountStatusFilter] = []
        var follows: [String] = []

        func record(_ filter: AccountStatusFilter) { filters.append(filter) }
        func recordFollow(_ name: String) { follows.append(name) }
    }

    private struct Failure: Error {}

    private func account(locked: Bool = false, statusesCount: Int = 0) throws -> Account {
        Account(
            id: "2",
            username: "bob",
            acct: "bob@remote.example",
            displayName: "Bob",
            avatar: try #require(URL(string: "https://example.social/avatars/bob.png")),
            locked: locked,
            statusesCount: statusesCount
        )
    }

    private func pinnedStatus() throws -> Status {
        Status(id: "10", createdAt: Date(timeIntervalSince1970: 0), account: try account(), content: "<p>固定</p>", spoilerText: "", url: nil)
    }

    private func makeAPI(
        calls: Calls = Calls(),
        account: Account,
        relationship: Relationship? = Relationship(id: "2"),
        failsAccount: Bool = false,
        pinned: [Status] = []
    ) -> ProfileStore.API {
        ProfileStore.API(
            account: { _ in
                if failsAccount { throw Failure() }
                return account
            },
            relationship: { _ in relationship },
            statuses: { _, filter, _ in
                await calls.record(filter)
                return filter.pinned ? pinned : []
            },
            follow: { id in
                await calls.recordFollow("follow")
                return Relationship(id: id, following: !account.locked, requested: account.locked)
            },
            unfollow: { id in
                await calls.recordFollow("unfollow")
                return Relationship(id: id)
            }
        )
    }

    @Test func showsKnownAccountBeforeLoading() throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(account: known))

        #expect(store.account == known)
        #expect(store.followState == .unknown)
    }

    @Test func loadProfileReplacesAccountRelationshipAndPinned() async throws {
        let fresh = try account(statusesCount: 42)
        let pinned = try pinnedStatus()
        let store = ProfileStore(account: try account(), myAccountID: "1", postsFilter: .standard, api: makeAPI(
            account: fresh,
            relationship: Relationship(id: "2", following: true),
            pinned: [pinned]
        ))

        try await store.loadProfile()

        #expect(store.account.statusesCount == 42)
        #expect(store.followState == .following)
        #expect(store.displayedPinned == [pinned])
    }

    /// アカウントの読み直しに失敗しても、関係と固定された投稿は反映する。
    @Test func loadProfileKeepsOtherResultsWhenOneFails() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(
            account: known,
            relationship: Relationship(id: "2", requested: true),
            failsAccount: true
        ))

        await #expect(throws: Failure.self) { try await store.loadProfile() }
        #expect(store.account == known)
        #expect(store.followState == .requested)
    }

    @Test func myselfHasNoFollowButtonAndSkipsRelationship() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: known.id, postsFilter: .standard, api: makeAPI(account: known, relationship: nil))

        try await store.loadProfile()

        #expect(store.followState == .myself)
    }

    @Test func lockedAccountAsksForRequest() async throws {
        let locked = try account(locked: true)
        let calls = Calls()
        let store = ProfileStore(account: locked, myAccountID: "1", postsFilter: .standard, api: makeAPI(calls: calls, account: locked))
        try await store.loadProfile()
        #expect(store.followState == .notFollowing(locked: true))

        try await store.toggleFollow()
        #expect(store.followState == .requested)

        // リクエスト中に押すと、リクエストを取り消す。
        try await store.toggleFollow()
        #expect(store.followState == .notFollowing(locked: true))
        #expect(await calls.follows == ["follow", "unfollow"])
    }

    @Test func postsFilterChangesQueryOnlyOnPostsTab() async throws {
        let known = try account()
        let calls = Calls()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(calls: calls, account: known))

        _ = try await store.timeline.loadInitial()
        let withReplies = try #require(store.setPostsFilter(ProfilePostsFilter(showsReplies: true, showsBoosts: false)))
        _ = try await withReplies.loadInitial()
        let media = try #require(store.select(.media))
        _ = try await media.loadInitial()
        // メディアの一覧では、投稿の絞り込みを変えても読み直さない。
        #expect(store.setPostsFilter(.standard) == nil)
        #expect(store.select(.media) == nil)

        #expect(await calls.filters == [
            AccountStatusFilter(excludesReplies: true, excludesReblogs: false),
            AccountStatusFilter(excludesReplies: false, excludesReblogs: true),
            AccountStatusFilter(onlyMedia: true),
        ])
    }

    @Test func pinnedAreShownOnlyOnPostsTab() async throws {
        let known = try account()
        let pinned = try pinnedStatus()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(account: known, pinned: [pinned]))
        try await store.loadProfile()

        _ = store.select(.media)

        #expect(store.displayedPinned.isEmpty)
    }
}
