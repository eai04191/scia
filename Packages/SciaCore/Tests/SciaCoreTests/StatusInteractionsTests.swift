import Foundation
import Synchronization
import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct StatusInteractionsTests {
    private struct Failure: Error {}

    private func status(id: String = "10", favourited: Bool = false, favourites: Int = 0, reblogged: Bool = false) throws -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "<p>\(id)</p>",
            spoilerText: "",
            url: nil,
            favourited: favourited,
            reblogged: reblogged,
            favouritesCount: favourites
        )
    }

    /// 1件の投稿を持ち、変換を当てた結果を記録する。
    private final class Shown {
        var status: Status
        var history: [Status] = []

        init(_ status: Status) {
            self.status = status
        }

        func update(_ id: Status.ID, _ transform: (Status) -> Status) {
            guard id == status.id else { return }
            status = transform(status)
            history.append(status)
        }
    }

    private func operations(favourite: @escaping @Sendable (Status.ID) async throws -> Status) -> StatusInteractions.Operations {
        StatusInteractions.Operations(
            favourite: favourite,
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )
    }

    private func reactionOperations(
        add: @escaping @Sendable (Status.ID, ReactionEmoji) async throws -> Status,
        remove: @escaping @Sendable (Status.ID, ReactionEmoji) async throws -> Status = { _, _ in throw Failure() }
    ) -> StatusInteractions.Operations {
        StatusInteractions.Operations(
            favourite: { _ in throw Failure() },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() },
            addEmojiReaction: add,
            removeEmojiReaction: remove
        )
    }

    private func status(reactions: [EmojiReaction]) -> Status {
        Status(
            id: "10",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "<p>10</p>",
            spoilerText: "",
            url: nil,
            emojiReactions: reactions
        )
    }

    /// 絵文字のリアクションも、押したらすぐ出し、サーバーの数で置き換える。
    @Test func showsEmojiReactionBeforeServerResponds() async throws {
        let emoji = ReactionEmoji(name: "👍")
        let shown = Shown(status(reactions: [EmojiReaction(emoji: emoji, count: 2, me: false)]))
        let fromServer = status(reactions: [EmojiReaction(emoji: emoji, count: 5, me: true)])
        let interactions = StatusInteractions(operations: reactionOperations { _, _ in fromServer }) { shown.update($0, $1) }

        #expect(try await interactions.toggle(.emojiReaction(emoji), on: shown.status))

        #expect(shown.history.map { $0.emojiReactions.map(\.count) } == [[3], [5]])
        #expect(shown.status.hasEmojiReaction(emoji))
    }

    /// Fedibirdは、付けられなかったほかのサーバーのカスタム絵文字でも投稿を返す。返った投稿に自分のリアクションがなければ、戻して失敗にする。
    @Test func revertsEmojiReactionServerDidNotApply() async throws {
        let emoji = ReactionEmoji(name: "blobcat", domain: "misskey.example")
        let shown = Shown(status(reactions: []))
        let fromServer = status(reactions: [])
        let interactions = StatusInteractions(operations: reactionOperations { _, _ in fromServer }) { shown.update($0, $1) }

        await #expect(throws: StatusInteractions.EmojiReactionNotApplied.self) {
            try await interactions.toggle(.emojiReaction(emoji), on: shown.status)
        }

        #expect(shown.history.map { $0.emojiReactions.count } == [1, 0])
    }

    /// 結果を待っている間に、同じ絵文字は送らず、ほかの絵文字は送る。
    @Test func emojiReactionsInFlightAreKeyedByEmoji() async throws {
        let thumbsUp = ReactionEmoji(name: "👍")
        let gate = Gate()
        let shown = Shown(status(reactions: []))
        let interactions = StatusInteractions(operations: reactionOperations { _, emoji in
            try await gate.wait()
            return Status(id: "10", createdAt: Date(timeIntervalSince1970: 0), account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil), content: "", spoilerText: "", url: nil, emojiReactions: [EmojiReaction(emoji: emoji, count: 1, me: true)])
        }) { shown.update($0, $1) }

        let first = Task { try await interactions.toggle(.emojiReaction(thumbsUp), on: shown.status) }
        try await waitUntil { interactions.inFlight.count == 1 }
        #expect(try await interactions.toggle(.emojiReaction(ReactionEmoji(name: "👍", url: nil)), on: shown.status) == false)
        let other = Task { try await interactions.toggle(.emojiReaction(ReactionEmoji(name: "🎉")), on: shown.status) }
        try await waitUntil { interactions.inFlight.count == 2 }
        gate.open()

        #expect(try await first.value)
        #expect(try await other.value)
        #expect(shown.status.emojiReactions.map(\.emoji.name) == ["👍", "🎉"])
    }

    /// ストリーミングの数は、リアクションした人に自分がいるかで、自分がしたかを決める。
    @Test func streamedReactionDecidesMeFromAccountIDs() {
        let emoji = ReactionEmoji(name: "👍")
        let shown = Shown(status(reactions: []))
        let interactions = StatusInteractions(operations: reactionOperations { _, _ in throw Failure() }) { shown.update($0, $1) }

        interactions.apply(EmojiReactionUpdate(statusID: "10", emoji: emoji, count: 2, accountIDs: ["1", "me"]), myAccountID: "me")
        #expect(shown.status.emojiReactions == [EmojiReaction(emoji: emoji, count: 2, me: true)])

        interactions.apply(EmojiReactionUpdate(statusID: "10", emoji: emoji, count: 1, accountIDs: ["1"]), myAccountID: "me")
        #expect(shown.status.emojiReactions == [EmojiReaction(emoji: emoji, count: 1, me: false)])
    }

    /// 結果を待っている間に届いた数では、押した状態を残す。押す前の数（0）が届いても消さない。
    @Test func streamedReactionKeepsPressedStateWhileWaiting() async throws {
        let emoji = ReactionEmoji(name: "👍")
        let gate = Gate()
        let shown = Shown(status(reactions: []))
        let interactions = StatusInteractions(operations: reactionOperations { _, emoji in
            try await gate.wait()
            return Status(id: "10", createdAt: Date(timeIntervalSince1970: 0), account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil), content: "", spoilerText: "", url: nil, emojiReactions: [EmojiReaction(emoji: emoji, count: 1, me: true)])
        }) { shown.update($0, $1) }

        let pressing = Task { try await interactions.toggle(.emojiReaction(emoji), on: shown.status) }
        try await waitUntil { interactions.inFlight.count == 1 }
        interactions.apply(EmojiReactionUpdate(statusID: "10", emoji: emoji, count: 0, accountIDs: []), myAccountID: "me")
        #expect(shown.status.emojiReactions.map(\.displayedCount) == [1])
        #expect(shown.status.hasEmojiReaction(emoji))

        gate.open()
        #expect(try await pressing.value)
    }

    /// 結果を待っている間にサーバーの数が届いてから失敗したら、数はそのままにし、自分がしたかだけを戻す。付けるときも外すときも。
    @Test(arguments: [false, true]) func failureAfterStreamedCountKeepsServerCount(wasOn: Bool) async throws {
        let emoji = ReactionEmoji(name: "👍")
        let gate = Gate()
        let shown = Shown(status(reactions: [EmojiReaction(emoji: emoji, count: 2, me: wasOn)]))
        let failing: @Sendable (Status.ID, ReactionEmoji) async throws -> Status = { _, _ in
            try await gate.wait()
            throw Failure()
        }
        let interactions = StatusInteractions(operations: reactionOperations(add: failing, remove: failing)) { shown.update($0, $1) }

        let pressing = Task { try await interactions.toggle(.emojiReaction(emoji), on: shown.status) }
        try await waitUntil { interactions.inFlight.count == 1 }
        interactions.apply(EmojiReactionUpdate(statusID: "10", emoji: emoji, count: 2, accountIDs: wasOn ? ["me", "1"] : ["1", "2"]), myAccountID: "me")
        gate.open()
        await #expect(throws: Failure.self) { try await pressing.value }

        #expect(shown.status.emojiReactions == [EmojiReaction(emoji: emoji, count: 2, me: wasOn)])
    }

    @Test func showsFavouriteBeforeServerRespondsThenAppliesResult() async throws {
        let shown = Shown(try status(favourites: 3))
        let fromServer = try status(favourited: true, favourites: 5)
        let interactions = StatusInteractions(operations: operations { _ in fromServer }) { shown.update($0, $1) }

        #expect(try await interactions.toggle(.favourite, on: shown.status))

        #expect(shown.history.map(\.favourited) == [true, true])
        #expect(shown.history.map(\.favouritesCount) == [4, 5])
        #expect(interactions.inFlight.isEmpty)
    }

    @Test func revertsWhenServerFails() async throws {
        let shown = Shown(try status(favourites: 3))
        let interactions = StatusInteractions(operations: operations { _ in throw Failure() }) { shown.update($0, $1) }
        var settled: [Status] = []
        interactions.onSettle = { _, status in settled.append(status) }

        await #expect(throws: Failure.self) { try await interactions.toggle(.favourite, on: shown.status) }

        #expect(shown.history.map(\.favourited) == [true, false])
        #expect(shown.status.favouritesCount == 3)
        #expect(settled.isEmpty)
    }

    /// サーバーが受け付けたら、結果を反映した元の投稿を知らせる。お気に入りの一覧に入れるのに使う。
    @Test func reportsSettledOriginalStatus() async throws {
        let original = try status(favourites: 3)
        let boost = Status(id: "99", createdAt: original.createdAt, account: original.account, content: "", spoilerText: "", url: nil, reblog: original)
        let fromServer = try status(favourited: true, favourites: 5)
        let interactions = StatusInteractions(operations: operations { _ in fromServer }) { _, _ in }
        var settled: [(StatusInteractions.Action, Status)] = []
        interactions.onSettle = { settled.append(($0, $1)) }

        #expect(try await interactions.toggle(.favourite, on: boost))

        #expect(settled.map(\.0) == [.favourite])
        #expect(settled.map(\.1.id) == ["10"])
        #expect(settled.map(\.1.favourited) == [true])
        #expect(settled.map(\.1.favouritesCount) == [5])
    }

    /// お気に入りの結果を待っている間にブックマークしたら、お気に入りを受け付けたときに知らせる投稿にも、ブックマークを含める。
    /// 押したときの古い状態で、お気に入りの一覧にブックマークしていない行として入れないため。
    @Test func settledStatusIncludesActionPressedWhileWaiting() async throws {
        let shown = Shown(try status())
        let gate = FetchGate()
        let favourited = try status(favourited: true, favourites: 1)
        let bookmarked = try status().settingBookmarked(true)
        let operations = StatusInteractions.Operations(
            favourite: { _ in
                await gate.wait()
                return favourited
            },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in bookmarked },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )
        let interactions = StatusInteractions(operations: operations) { shown.update($0, $1) }
        var settled: [(StatusInteractions.Action, Status)] = []
        interactions.onSettle = { settled.append(($0, $1)) }
        let original = shown.status

        let favourite = Task { try await interactions.toggle(.favourite, on: original) }
        await gate.waitUntilWaiting()
        #expect(try await interactions.toggle(.bookmark, on: shown.status))
        await gate.open()
        #expect(try await favourite.value)

        #expect(settled.map(\.0) == [.bookmark, .favourite])
        #expect(settled.map(\.1.bookmarked) == [true, true])
        #expect(settled.map(\.1.favourited) == [true, true])
    }

    @Test func ignoresSameActionWhileWaiting() async throws {
        let shown = Shown(try status())
        let gate = FetchGate()
        let fromServer = try status(favourited: true, favourites: 1)
        let calls = Mutex(0)
        let interactions = StatusInteractions(operations: operations { _ in
            calls.withLock { $0 += 1 }
            await gate.wait()
            return fromServer
        }) { shown.update($0, $1) }
        let original = shown.status

        let first = Task { try await interactions.toggle(.favourite, on: original) }
        await gate.waitUntilWaiting()
        #expect(try await !interactions.toggle(.favourite, on: shown.status))
        await gate.open()

        #expect(try await first.value)
        #expect(calls.withLock { $0 } == 1)
        #expect(shown.status.favourited)
    }

    /// 応答は対象の操作の状態だけを反映する。待っている間に届いた編集や、並行して成功した別の操作を古い内容で戻さない。
    @Test func resultOnlyUpdatesStateOfItsAction() async throws {
        let shown = Shown(try status())
        let gate = FetchGate()
        // サーバーが返すのは、編集とブーストより前の内容。
        let staleFromServer = try status(favourited: true, favourites: 1)
        let interactions = StatusInteractions(operations: StatusInteractions.Operations(
            favourite: { _ in
                await gate.wait()
                return staleFromServer
            },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in staleFromServer.settingFavourited(false).settingReblogged(true) },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )) { shown.update($0, $1) }

        let favourite = Task { try await interactions.toggle(.favourite, on: shown.status) }
        await gate.waitUntilWaiting()
        _ = try await interactions.toggle(.reblog, on: shown.status)
        shown.update("10") { _ in
            Status(id: "10", createdAt: Date(timeIntervalSince1970: 0), account: staleFromServer.account, content: "<p>編集後</p>", spoilerText: "", url: nil, favourited: true, reblogged: true, favouritesCount: 1, reblogsCount: 1)
        }
        await gate.open()
        _ = try await favourite.value

        #expect(shown.status.favourited)
        #expect(shown.status.reblogged)
        #expect(shown.status.content == "<p>編集後</p>")
    }

    @Test func unboostsWhenAlreadyBoostedAndTargetsOriginalOfBoost() async throws {
        let original = try status(reblogged: true)
        let boost = Status(id: "20", createdAt: Date(timeIntervalSince1970: 0), account: original.account, content: "", spoilerText: "", url: nil, reblog: original)
        let shown = Shown(original)
        let requested = Mutex<[String]>([])
        let interactions = StatusInteractions(operations: StatusInteractions.Operations(
            favourite: { _ in throw Failure() },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { id in
                requested.withLock { $0.append(id) }
                return original.settingReblogged(false)
            },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )) { shown.update($0, $1) }

        _ = try await interactions.toggle(.reblog, on: boost)

        #expect(requested.withLock { $0 } == ["10"])
        #expect(!shown.status.reblogged)
    }

    @Test func bookmarkShowsBeforeServerRespondsAndRevertsOnFailure() async throws {
        let shown = Shown(try status())
        let interactions = StatusInteractions(operations: StatusInteractions.Operations(
            favourite: { _ in throw Failure() },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )) { shown.update($0, $1) }

        await #expect(throws: Failure.self) { try await interactions.toggle(.bookmark, on: shown.status) }

        #expect(shown.history.map(\.bookmarked) == [true, false])
    }

    @Test func unbookmarksWhenAlreadyBookmarked() async throws {
        let bookmarked = try status().settingBookmarked(true)
        let shown = Shown(bookmarked)
        let interactions = StatusInteractions(operations: StatusInteractions.Operations(
            favourite: { _ in throw Failure() },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in bookmarked.settingBookmarked(false) },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )) { shown.update($0, $1) }

        #expect(try await interactions.toggle(.bookmark, on: shown.status))

        #expect(shown.history.map(\.bookmarked) == [false, false])
    }

    @Test func mutesConversationOfOriginalOfBoostAndAppliesResult() async throws {
        let original = try status()
        let boost = Status(id: "20", createdAt: Date(timeIntervalSince1970: 0), account: original.account, content: "", spoilerText: "", url: nil, reblog: original)
        let shown = Shown(original)
        let requested = Mutex<[String]>([])
        let interactions = StatusInteractions(operations: StatusInteractions.Operations(
            favourite: { _ in throw Failure() },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { id in
                requested.withLock { $0.append(id) }
                return original.settingMuted(true)
            },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )) { shown.update($0, $1) }

        #expect(try await interactions.toggle(.muteConversation, on: boost))

        #expect(requested.withLock { $0 } == ["10"])
        #expect(shown.history.map(\.muted) == [true, true])
    }

    @Test func unpinsWhenAlreadyPinnedAndRevertsOnFailure() async throws {
        let shown = Shown(try status().settingPinned(true))
        let interactions = StatusInteractions(operations: StatusInteractions.Operations(
            favourite: { _ in throw Failure() },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )) { shown.update($0, $1) }

        await #expect(throws: Failure.self) { try await interactions.toggle(.pin, on: shown.status) }

        #expect(shown.history.map(\.pinned) == [false, true])
    }

    @Test func reblogsWithChosenVisibility() async throws {
        let shown = Shown(try status())
        let fromServer = try status(reblogged: true)
        let requested = Mutex<[ReblogVisibility]>([])
        let interactions = StatusInteractions(operations: StatusInteractions.Operations(
            favourite: { _ in throw Failure() },
            unfavourite: { _ in throw Failure() },
            reblog: { _, visibility in
                requested.withLock { $0.append(visibility) }
                return fromServer
            },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )) { shown.update($0, $1) }

        #expect(try await interactions.toggle(.reblog, on: shown.status, reblogVisibility: .unlisted))

        #expect(requested.withLock { $0 } == [.unlisted])
        #expect(shown.status.reblogged)
    }
}
