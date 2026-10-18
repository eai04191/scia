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

    /// フォローを送ったか。送ったあとに読むアカウントを差し替えるのに使う。
    private actor Followed {
        var value = false
        func set() { value = true }
    }

    /// 関係の読み込みを、決めた回数だけ失敗させる。
    private actor RelationshipFailures {
        var remaining: Int
        init(_ count: Int) { remaining = count }
        func consume() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    private func account(locked: Bool = false, statusesCount: Int = 0) throws -> Account {
        let avatar = try #require(URL(string: "https://example.social/avatars/bob.png"))
        return Account(
            id: "2",
            username: "bob",
            acct: "bob@remote.example",
            displayName: "Bob",
            avatar: avatar,
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
        failsRelationshipTimes: Int = 0,
        failsPinned: Bool = false,
        pinned: [Status] = [],
        accountAfterFollow: Account? = nil
    ) -> ProfileStore.API {
        let followed = Followed()
        let relationshipFailures = RelationshipFailures(failsRelationshipTimes)
        return ProfileStore.API(
            account: { _ in
                if failsAccount { throw Failure() }
                if let accountAfterFollow, await followed.value { return accountAfterFollow }
                return account
            },
            relationship: { _ in
                if await relationshipFailures.consume() { throw Failure() }
                return relationship
            },
            statuses: { _, filter, _ in
                await calls.record(filter)
                if failsPinned, filter.pinned { throw Failure() }
                return TimelinePage(statuses: filter.pinned ? pinned : [], isRegenerating: false)
            },
            follow: { id in
                await calls.recordFollow("follow")
                await followed.set()
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

        let failures = await store.loadProfile()

        #expect(failures.isEmpty)
        #expect(store.account.statusesCount == 42)
        #expect(store.followState == .following)
        #expect(store.displayedPinned == [pinned])
    }

    @Test func removesDeletedPinnedStatus() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(account: known, pinned: [try pinnedStatus()]))
        _ = await store.loadProfile()

        #expect(store.removeStatus("10"))
        #expect(store.displayedPinned.isEmpty)
        #expect(!store.removeStatus("10"))
    }

    /// 削除の前に読み始めた固定された投稿の応答が、削除のあとに届いても、削除した投稿を戻さない。
    @Test func deletedPinnedStatusDoesNotReturnFromReadStartedBefore() async throws {
        let known = try account()
        let pinned = try pinnedStatus()
        let gate = PageGate(TimelinePage(statuses: [pinned], isRegenerating: false))
        let api = ProfileStore.API(
            account: { _ in known },
            relationship: { _ in nil },
            statuses: { _, filter, _ in filter.pinned ? await gate.fetch() : TimelinePage(statuses: [], isRegenerating: false) },
            follow: { _ in throw Failure() },
            unfollow: { _ in throw Failure() }
        )
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: api)
        await gate.hold()
        let read = Task { await store.loadProfile() }
        await gate.waitForRequest()

        store.removeStatus("10")
        await gate.release()
        _ = await read.value

        #expect(store.displayedPinned.isEmpty)
    }

    /// アカウントの読み直しに失敗しても、関係と固定された投稿は反映する。失敗はアカウントの分だけ返す。
    @Test func loadProfileKeepsOtherResultsWhenOneFails() async throws {
        let known = try account()
        let pinned = try pinnedStatus()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(
            account: known,
            relationship: Relationship(id: "2", requested: true),
            failsAccount: true,
            pinned: [pinned]
        ))

        let failures = await store.loadProfile()

        #expect(failures.account is Failure)
        #expect(failures.relationship == nil)
        #expect(failures.pinned == nil)
        #expect(store.account == known)
        #expect(store.followState == .requested)
        #expect(store.displayedPinned == [pinned])
    }

    /// 固定された投稿を読めなくても、フォローのボタンには関係しない。
    @Test func pinnedFailureIsReportedSeparately() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(
            account: known,
            relationship: Relationship(id: "2", following: true),
            failsPinned: true
        ))

        let failures = await store.loadProfile()

        #expect(failures.pinned is Failure)
        #expect(failures.account == nil)
        #expect(failures.relationship == nil)
        #expect(store.followState == .following)
    }

    /// 関係を読めなかったら、フォローのボタンを黙って消さず、読めなかったことを示す。読み直せたら、ボタンに戻す。
    @Test func relationshipFailureCanBeRetried() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(
            account: known,
            relationship: Relationship(id: "2", following: true),
            failsRelationshipTimes: 2
        ))

        let failures = await store.loadProfile()
        #expect(failures.relationship is Failure)
        #expect(failures.account == nil)
        #expect(store.followState == .loadFailed)

        // 読み直しにも失敗したら、読めなかったままにする。
        await #expect(throws: Failure.self) { try await store.reloadRelationship() }
        #expect(store.followState == .loadFailed)
        #expect(!store.isReloadingRelationship)

        try await store.reloadRelationship()
        #expect(store.followState == .following)
    }

    /// 読めなかった関係を、フォローやフォローの解除で上書きしない。
    @Test func toggleFollowDoesNothingWhileRelationshipIsUnreadable() async throws {
        let known = try account()
        let calls = Calls()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(calls: calls, account: known, failsRelationshipTimes: 1))
        _ = await store.loadProfile()

        #expect(try await store.toggleFollow() == false)
        #expect(await calls.follows.isEmpty)
    }

    @Test func myselfHasNoFollowButtonAndSkipsRelationship() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: known.id, postsFilter: .standard, api: makeAPI(account: known, relationship: nil))

        _ = await store.loadProfile()

        #expect(store.followState == .myself)
    }

    @Test func lockedAccountAsksForRequest() async throws {
        let locked = try account(locked: true)
        let calls = Calls()
        let store = ProfileStore(account: locked, myAccountID: "1", postsFilter: .standard, api: makeAPI(calls: calls, account: locked))
        _ = await store.loadProfile()
        #expect(store.followState == .notFollowing(locked: true))

        try await store.toggleFollow()
        #expect(store.followState == .requested)

        // リクエスト中に押すと、リクエストを取り消す。
        try await store.toggleFollow()
        #expect(store.followState == .notFollowing(locked: true))
        #expect(await calls.follows == ["follow", "unfollow"])
    }

    /// フォローのAPIは関係だけを返すので、フォロワー数はアカウントを読み直して変える。
    @Test func reloadAccountReflectsFollowersCountAfterFollow() async throws {
        let known = try account()
        let followedAccount = Account(id: known.id, username: known.username, acct: known.acct, displayName: known.displayName, avatar: known.avatar, followersCount: 1)
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, api: makeAPI(account: known, accountAfterFollow: followedAccount))
        _ = await store.loadProfile()
        #expect(store.account.followersCount == 0)

        #expect(try await store.toggleFollow())
        try await store.reloadAccount()

        #expect(store.followState == .following)
        #expect(store.account.followersCount == 1)
    }

    /// 自分のアカウントでは何も送らないので、読み直しも要らない。
    @Test func toggleFollowReportsNothingSentForMyself() async throws {
        let known = try account()
        let calls = Calls()
        let store = ProfileStore(account: known, myAccountID: known.id, postsFilter: .standard, api: makeAPI(calls: calls, account: known))

        #expect(try await store.toggleFollow() == false)
        #expect(await calls.follows.isEmpty)
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
        _ = await store.loadProfile()

        _ = store.select(.media)

        #expect(store.displayedPinned.isEmpty)
    }
}
