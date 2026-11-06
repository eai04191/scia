import Foundation
import Synchronization
import SciaTesting
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

    /// サーバーで固定されている投稿。固定したあとに読み直す応答を変えるのに使う。
    private actor PinnedOnServer {
        var statuses: [Status] = []
        func set(_ statuses: [Status]) { self.statuses = statuses }
    }

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
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(account: known))

        #expect(store.account == known)
        #expect(store.followState == .unknown)
    }

    @Test func editedAccountReplacesOnlySameAccount() throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "2", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(account: known))
        let edited = Account(id: "2", username: "bob", acct: "bob", displayName: "編集したBob", avatar: known.avatar)
        let other = Account(id: "3", username: "carol", acct: "carol", displayName: "Carol", avatar: known.avatar)

        store.apply(edited: other)
        #expect(store.account == known)

        store.apply(edited: edited)
        #expect(store.account == edited)
    }

    @Test func loadProfileReplacesAccountRelationshipAndPinned() async throws {
        let fresh = try account(statusesCount: 42)
        let pinned = try pinnedStatus()
        let store = ProfileStore(account: try account(), myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(
            account: fresh,
            relationship: Relationship(id: "2", following: true),
            pinned: [pinned]
        ))

        let failures = await store.loadProfile()

        #expect(failures.isEmpty)
        #expect(store.account.statusesCount == 42)
        #expect(store.followState == .following)
        #expect(store.pinned == [pinned])
    }

    /// 自分のプロフィールでも関係を読み、自分に書いたメモを出せるようにする。フォローのボタンは出さないまま。メモを書いたあとの関係も反映する。
    @Test func myselfLoadsRelationshipForNote() async throws {
        let known = try account()
        let cache = localRelationships()
        let store = ProfileStore(account: known, myAccountID: "2", postsFilter: .standard, relationshipCache: cache, api: makeAPI(
            account: known,
            relationship: Relationship(id: "2", note: "TODO")
        ))

        let failures = await store.loadProfile()

        #expect(failures.isEmpty)
        #expect(store.followState == .myself)
        #expect(store.relationship?.note == "TODO")
        #expect(cache[known.id]?.note == "TODO")

        store.apply(Relationship(id: "2", note: "済んだ"))
        #expect(store.relationship?.note == "済んだ")
        #expect(store.followState == .myself)
    }

    /// 同じ相手を開き直したら、読み込む前から前に読んだ関係で始める。読んだら新しい関係で置き換える。
    @Test func reopenedProfileStartsFromCachedRelationship() async throws {
        let known = try account()
        let cache = localRelationships()
        let first = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: cache, api: makeAPI(
            account: known,
            relationship: Relationship(id: "2", following: true, followedBy: true)
        ))
        _ = await first.loadProfile()

        let reopened = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: cache, api: makeAPI(
            account: known,
            relationship: Relationship(id: "2")
        ))
        #expect(reopened.followState == .following)
        #expect(reopened.relationship?.followedBy == true)

        _ = await reopened.loadProfile()
        #expect(reopened.followState == .notFollowing(locked: false))
        #expect(cache[known.id] == Relationship(id: "2"))
    }

    /// フォローを変えたら、開き直したときも変えたあとの関係で始める。
    @Test func followChangeIsCachedForReopening() async throws {
        let known = try account()
        let cache = localRelationships()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: cache, api: makeAPI(account: known))
        _ = await store.loadProfile()

        try await store.toggleFollow()

        #expect(cache[known.id]?.following == true)
    }

    /// 読み込みのアカウントの応答を止め、読み直しのアカウントの応答はすぐ返すAPI。止めた方は、届いた時点で古い。
    private func makeAPIWithGatedFirstAccount(old: Account, new: Account, gate: Gate) -> ProfileStore.API {
        let calls = Mutex(0)
        return ProfileStore.API(
            account: { _ in
                let call = calls.withLock { calls in
                    defer { calls += 1 }
                    return calls
                }
                guard call == 0 else { return new }
                await gate.enter()
                return old
            },
            relationship: { id in Relationship(id: id) },
            statuses: { _, _, _ in TimelinePage(statuses: [], isRegenerating: false) },
            follow: { id in Relationship(id: id, following: true) },
            unfollow: { id in Relationship(id: id) }
        )
    }

    /// フォローしたあとの読み直しのように、あとから頼んだアカウントの読み直しが先に届いたら、前に頼んだ読み込みの応答が後から届いても、古い数で戻さない。
    @Test func accountRequestedEarlierDoesNotOverwriteLaterReload() async throws {
        let old = try account(statusesCount: 1)
        let new = try account(statusesCount: 2)
        let gate = Gate()
        let store = ProfileStore(account: old, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPIWithGatedFirstAccount(old: old, new: new, gate: gate))

        let load = Task { await store.loadProfile() }
        try await waitUntil { await gate.isEntered }
        try await store.reloadAccount()
        #expect(store.account.statusesCount == 2)
        await gate.open()
        _ = await load.value

        #expect(store.account.statusesCount == 2)
    }

    /// 編集して保存したプロフィールは、保存する前に頼んだ読み込みの応答が後から届いても、編集する前に戻さない。
    @Test func editedAccountWinsOverEarlierLoad() async throws {
        let old = try account(statusesCount: 1)
        let edited = try account(statusesCount: 3)
        let gate = Gate()
        let store = ProfileStore(account: old, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPIWithGatedFirstAccount(old: old, new: old, gate: gate))

        let load = Task { await store.loadProfile() }
        try await waitUntil { await gate.isEntered }
        store.apply(edited: edited)
        await gate.open()
        _ = await load.value

        #expect(store.account.statusesCount == 3)
    }

    /// 応答を、開けるまで止める。
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isEntered = false

        func enter() async {
            isEntered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// 前に読んだ関係から始めると、読み直しが終わる前にフォローを送れる。フォローより前に頼んだ読み直しの応答が後から届いても、フォローの結果を古い関係で戻さない。
    @Test func relationshipRequestedBeforeFollowDoesNotOverwriteFollowResult() async throws {
        let known = try account()
        let cache = localRelationships()
        cache[known.id] = Relationship(id: "2")
        let gate = Gate()
        let api = ProfileStore.API(
            account: { _ in known },
            relationship: { id in
                await gate.enter()
                return Relationship(id: id)
            },
            statuses: { _, _, _ in TimelinePage(statuses: [], isRegenerating: false) },
            follow: { id in Relationship(id: id, following: true) },
            unfollow: { id in Relationship(id: id) }
        )
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: cache, api: api)

        let load = Task { await store.loadProfile() }
        try await waitUntil { await gate.isEntered }
        try await store.toggleFollow()
        await gate.open()
        _ = await load.value

        #expect(store.followState == .following)
        #expect(cache[known.id]?.following == true)
    }

    /// ユーザーのメニューで変えた関係を反映して覚え、変える前に頼んだ関係の読み込みが後から届いても戻さない。
    @Test func appliedRelationshipWinsOverEarlierLoad() async throws {
        let known = try account()
        let cache = localRelationships()
        let gate = Gate()
        let api = ProfileStore.API(
            account: { _ in known },
            relationship: { id in
                await gate.enter()
                return Relationship(id: id)
            },
            statuses: { _, _, _ in TimelinePage(statuses: [], isRegenerating: false) },
            follow: { id in Relationship(id: id, following: true) },
            unfollow: { id in Relationship(id: id) }
        )
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: cache, api: api)

        let load = Task { await store.loadProfile() }
        try await waitUntil { await gate.isEntered }
        store.apply(Relationship(id: "2", blocking: true))
        await gate.open()
        _ = await load.value

        #expect(store.followState == .blocked)
        #expect(cache[known.id]?.blocking == true)
    }

    /// フォローのボタンの応答を待つ間に、ユーザーのメニューで関係を変えたら、遅れて届いたフォローの応答で戻さない。
    @Test func appliedRelationshipWinsOverEarlierFollowResponse() async throws {
        let known = try account()
        let cache = localRelationships()
        cache[known.id] = Relationship(id: "2")
        let gate = Gate()
        let api = ProfileStore.API(
            account: { _ in known },
            relationship: { id in Relationship(id: id) },
            statuses: { _, _, _ in TimelinePage(statuses: [], isRegenerating: false) },
            follow: { id in
                await gate.enter()
                return Relationship(id: id, following: true)
            },
            unfollow: { id in Relationship(id: id) }
        )
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: cache, api: api)

        let follow = Task { try await store.toggleFollow() }
        try await waitUntil { await gate.isEntered }
        store.apply(Relationship(id: "2", blocking: true))
        await gate.open()
        _ = try await follow.value

        #expect(store.followState == .blocked)
        #expect(cache[known.id]?.blocking == true)
    }

    /// 読み直しに失敗しても、前に読んだ関係があれば、読めなかった表示にせずそのまま出す。
    @Test func cachedRelationshipStaysWhenReloadFails() async throws {
        let known = try account()
        let cache = localRelationships()
        cache[known.id] = Relationship(id: "2", following: true)
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: cache, api: makeAPI(account: known, failsRelationshipTimes: 1))

        let failures = await store.loadProfile()

        #expect(failures.relationship is Failure)
        #expect(store.followState == .following)
    }

    /// 固定された投稿を読み終えたかは、読めたときも読めなかったときも分かる。タイムラインは、これを待ってから固定された投稿と一緒に出す。
    @Test(arguments: [false, true])
    func pinnedSettlesWhetherLoadedOrFailed(failsPinned: Bool) async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(account: known, failsPinned: failsPinned))
        #expect(!store.isShelvesSettled)

        _ = await store.loadProfile()

        #expect(store.isShelvesSettled)
    }

    /// 注目のハッシュタグと紹介している人を、固定された投稿と一緒に読む。紹介している人に続きがあるかも分かる。
    @Test func loadProfileReadsFeaturedTagsAndEndorsements() async throws {
        let known = try account()
        let tag = FeaturedTag(id: "7", name: "猫写真", statusesCount: 3)
        let endorsed = try account(statusesCount: 1)
        let pageSizes = Mutex<[Int]>([])
        var api = makeAPI(account: known)
        api.featuredTags = { id in
            #expect(id == "2")
            return [tag]
        }
        api.endorsements = { id, limit in
            #expect(id == "2")
            pageSizes.withLock { $0.append(limit) }
            return AccountListPage(accounts: [endorsed], nextMaxID: "100")
        }
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: api)

        let failures = await store.loadProfile()

        #expect(failures.isEmpty)
        #expect(store.featuredTags == [tag])
        #expect(store.endorsements == [endorsed])
        #expect(store.hasMoreEndorsements)
        #expect(pageSizes.withLock { $0 } == [ProfileStore.endorsementsPageSize])
    }

    /// 注目のハッシュタグや紹介している人を読めなくても、棚を出さずにタイムラインを出せるよう、読み終えたことにする。
    /// 4.4より前のサーバーでは、ほかの人の紹介している人を読めない。
    @Test(arguments: [(true, false), (false, true), (true, true)])
    func shelvesSettleWhenFeaturedFails(failsTags: Bool, failsEndorsements: Bool) async throws {
        let known = try account()
        var api = makeAPI(account: known)
        api.featuredTags = { _ in
            if failsTags { throw Failure() }
            return [FeaturedTag(id: "7", name: "猫写真", statusesCount: 3)]
        }
        api.endorsements = { _, _ in
            if failsEndorsements { throw Failure() }
            return AccountListPage(accounts: [known], nextMaxID: nil)
        }
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: api)

        let failures = await store.loadProfile()

        #expect(store.isShelvesSettled)
        #expect((failures.featuredTags != nil) == failsTags)
        #expect((failures.endorsements != nil) == failsEndorsements)
        #expect(store.featuredTags.isEmpty == failsTags)
        #expect(store.endorsements.isEmpty == failsEndorsements)
        #expect(Set(failures.all.map(\.part)) == Set((failsTags ? ["featuredTags"] : []) + (failsEndorsements ? ["endorsements"] : [])))
    }

    /// 自分のプロフィールで載せるものを変えたあと、注目のハッシュタグと紹介している人だけを読み直す。
    /// 読めなかったほうは前のまま残し、投げる。
    @Test func reloadFeaturedReplacesWhatWasRead() async throws {
        let known = try account()
        let before = FeaturedTag(id: "7", name: "猫写真", statusesCount: 3)
        let after = FeaturedTag(id: "8", name: "犬写真", statusesCount: 1)
        let reads = Mutex(0)
        var api = makeAPI(account: known)
        api.featuredTags = { _ in
            let read = reads.withLock { count in
                count += 1
                return count
            }
            return read == 1 ? [before] : [before, after]
        }
        let endorsementReads = Mutex(0)
        api.endorsements = { _, _ in
            let read = endorsementReads.withLock { count in
                count += 1
                return count
            }
            if read > 1 { throw Failure() }
            return AccountListPage(accounts: [known], nextMaxID: nil)
        }
        let store = ProfileStore(account: known, myAccountID: "2", postsFilter: .standard, relationshipCache: localRelationships(), api: api)
        _ = await store.loadProfile()

        await #expect(throws: Failure.self) { try await store.reloadFeatured() }

        #expect(store.featuredTags == [before, after])
        #expect(store.endorsements == [known])
    }

    /// 続けて読み直したとき、先に読み始めた読み直しの応答が遅れて届いても、あとの読み直しの結果を戻さない。
    @Test func olderFeaturedReloadDoesNotOverwriteNewerOne() async throws {
        let known = try account()
        let old = FeaturedTag(id: "7", name: "猫写真", statusesCount: 3)
        let gate = Gate()
        let calls = Mutex(0)
        var api = makeAPI(account: known)
        api.featuredTags = { _ in
            // 1回目は最初の読み込み、2回目は止めておく読み直し、3回目はあとの読み直し。
            let call = calls.withLock { count in
                count += 1
                return count
            }
            if call == 2 {
                await gate.enter()
                return [old]
            }
            return []
        }
        let store = ProfileStore(account: known, myAccountID: "2", postsFilter: .standard, relationshipCache: localRelationships(), api: api)
        _ = await store.loadProfile()
        let earlier = Task { try await store.reloadFeatured() }
        try await waitUntil { await gate.isEntered }

        try await store.reloadFeatured()
        await gate.open()
        try await earlier.value

        #expect(store.featuredTags.isEmpty)
    }

    /// プロフィールの場所で隠すフィルターに一致した固定された投稿は出さない。編集で一致しなくなれば出す。
    @Test func hidesFilteredPinnedStatus() async throws {
        let known = try account()
        let hide = FilterResult(filter: FilterResult.Filter(id: "1", title: "x", context: [.account], filterAction: .hide))
        let hidden = Status(id: "10", createdAt: Date(timeIntervalSince1970: 0), account: known, content: "<p>固定</p>", spoilerText: "", url: nil, filtered: [hide])
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(account: known, pinned: [hidden]))
        _ = await store.loadProfile()
        #expect(store.pinned.isEmpty)

        let edited = try pinnedStatus()
        store.updateStatus("10") { _ in edited }
        #expect(store.pinned.map(\.id) == ["10"])
    }

    @Test func removesDeletedPinnedStatus() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(account: known, pinned: [try pinnedStatus()]))
        _ = await store.loadProfile()

        #expect(store.removeStatus("10"))
        #expect(store.pinned.isEmpty)
        #expect(!store.removeStatus("10"))
    }

    /// 固定したり外したりしたあとに、固定された投稿だけを読み直す。
    @Test func reloadPinnedReplacesPinnedStatuses() async throws {
        let known = try account()
        let pinned = try pinnedStatus()
        let server = PinnedOnServer()
        let api = ProfileStore.API(
            account: { _ in known },
            relationship: { _ in nil },
            statuses: { _, filter, _ in TimelinePage(statuses: filter.pinned ? await server.statuses : [], isRegenerating: false) },
            follow: { _ in throw Failure() },
            unfollow: { _ in throw Failure() }
        )
        let store = ProfileStore(account: known, myAccountID: "2", postsFilter: .standard, relationshipCache: localRelationships(), api: api)
        _ = await store.loadProfile()
        #expect(store.pinned.isEmpty)

        await server.set([pinned])
        try await store.reloadPinned()

        #expect(store.pinned == [pinned])
    }

    /// 固定と解除を続けて押し、先に読み始めた読み直しの応答が遅れて届いても、あとの読み直しの結果を戻さない。
    @Test func olderPinnedReloadDoesNotOverwriteNewerOne() async throws {
        let known = try account()
        let pinned = try pinnedStatus()
        let gate = PageGate(TimelinePage(statuses: [pinned], isRegenerating: false))
        let server = PinnedOnServer()
        let calls = Mutex(0)
        let api = ProfileStore.API(
            account: { _ in known },
            relationship: { _ in nil },
            statuses: { _, filter, _ in
                guard filter.pinned else { return TimelinePage(statuses: [], isRegenerating: false) }
                // 1回目は最初の読み込み、2回目は固定したあとの読み直しで、止めておく。3回目は外したあとの読み直し。
                let call = calls.withLock { count in
                    count += 1
                    return count
                }
                return call == 2 ? await gate.fetch() : TimelinePage(statuses: await server.statuses, isRegenerating: false)
            },
            follow: { _ in throw Failure() },
            unfollow: { _ in throw Failure() }
        )
        let store = ProfileStore(account: known, myAccountID: "2", postsFilter: .standard, relationshipCache: localRelationships(), api: api)
        _ = await store.loadProfile()
        await gate.hold()
        let afterPin = Task { try await store.reloadPinned() }
        await gate.waitForRequest()

        try await store.reloadPinned()
        await gate.release()
        try await afterPin.value

        #expect(store.pinned.isEmpty)
    }

    /// 読み直しを待つ間に反映したお気に入りを、読み始めた時点の応答で戻さない。
    @Test func pinnedReloadKeepsUpdatesMadeWhileWaiting() async throws {
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
        let store = ProfileStore(account: known, myAccountID: "2", postsFilter: .standard, relationshipCache: localRelationships(), api: api)
        _ = await store.loadProfile()
        await gate.hold()
        let reload = Task { try await store.reloadPinned() }
        await gate.waitForRequest()

        store.updateStatus("10") { $0.settingFavourited(true) }
        await gate.release()
        try await reload.value

        #expect(store.pinned.map(\.favourited) == [true])
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
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: api)
        await gate.hold()
        let read = Task { await store.loadProfile() }
        await gate.waitForRequest()

        store.removeStatus("10")
        await gate.release()
        _ = await read.value

        #expect(store.pinned.isEmpty)
    }

    /// アカウントの読み直しに失敗しても、関係と固定された投稿は反映する。失敗はアカウントの分だけ返す。
    @Test func loadProfileKeepsOtherResultsWhenOneFails() async throws {
        let known = try account()
        let pinned = try pinnedStatus()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(
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
        #expect(store.pinned == [pinned])
    }

    /// 固定された投稿を読めなくても、フォローのボタンには関係しない。
    @Test func pinnedFailureIsReportedSeparately() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(
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
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(
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
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(calls: calls, account: known, failsRelationshipTimes: 1))
        _ = await store.loadProfile()

        #expect(try await store.toggleFollow() == false)
        #expect(await calls.follows.isEmpty)
    }

    @Test func myselfHasNoFollowButtonAndSkipsRelationship() async throws {
        let known = try account()
        let store = ProfileStore(account: known, myAccountID: known.id, postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(account: known, relationship: nil))

        _ = await store.loadProfile()

        #expect(store.followState == .myself)
    }

    @Test func lockedAccountAsksForRequest() async throws {
        let locked = try account(locked: true)
        let calls = Calls()
        let store = ProfileStore(account: locked, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(calls: calls, account: locked))
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
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(account: known, accountAfterFollow: followedAccount))
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
        let store = ProfileStore(account: known, myAccountID: known.id, postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(calls: calls, account: known))

        #expect(try await store.toggleFollow() == false)
        #expect(await calls.follows.isEmpty)
    }

    @Test func postsFilterChangesQueryOnlyOnPostsTab() async throws {
        let known = try account()
        let calls = Calls()
        let store = ProfileStore(account: known, myAccountID: "1", postsFilter: .standard, relationshipCache: localRelationships(), api: makeAPI(calls: calls, account: known))

        _ = try await store.timeline.loadInitial()
        let withReplies = try #require(store.setPostsFilter(ProfilePostsFilter(showsReplies: true, showsBoosts: false)))
        _ = try await withReplies.loadInitial()
        let media = try #require(store.select(.media))
        _ = try await media.loadInitial()
        // メディアのタイムラインでは、投稿の絞り込みを変えても読み直さない。
        #expect(store.setPostsFilter(.standard) == nil)
        #expect(store.select(.media) == nil)

        #expect(await calls.filters == [
            AccountStatusFilter(excludesReplies: true, excludesReblogs: false),
            AccountStatusFilter(excludesReplies: false, excludesReblogs: true),
            AccountStatusFilter(onlyMedia: true),
        ])
    }
}

/// プロフィールの状態は、関係を覚えて読み出すだけで、キャッシュから読み直さない。読み直したらテストを失敗させる。
@MainActor
private func localRelationships() -> RelationshipCache {
    RelationshipCache { _ in
        Issue.record("ProfileStoreがRelationshipCacheから関係を読み直した")
        return []
    }
}
