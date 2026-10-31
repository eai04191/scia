import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
@Suite(.requestPurpose(.action))
struct ListMembershipModelTests {
    private struct Failure: Error {}

    /// 送ったものを記録し、門で止められる通信。
    private final class Server: Sendable {
        let lists: [MastodonList]
        let containing: [String]
        let relationship: Relationship
        let followed: Relationship
        let addGate: Gate
        let failsAdd: Bool
        let failsFollow: Bool
        private let log = Mutex<[String]>([])
        var sent: [String] { log.withLock { $0 } }

        init(
            lists: [MastodonList] = [MastodonList(id: "1", title: "友だち"), MastodonList(id: "2", title: "仕事")],
            containing: [String] = ["2"],
            relationship: Relationship = Relationship(id: "7", following: true),
            followed: Relationship = Relationship(id: "7", following: true),
            addGate: Gate = Gate(isOpen: true),
            failsAdd: Bool = false,
            failsFollow: Bool = false
        ) {
            self.lists = lists
            self.containing = containing
            self.relationship = relationship
            self.followed = followed
            self.addGate = addGate
            self.failsAdd = failsAdd
            self.failsFollow = failsFollow
        }

        var api: ListMembershipModel.API {
            ListMembershipModel.API(
                lists: { self.lists },
                listsContaining: { self.lists.filter { self.containing.contains($0.id) } },
                relationship: { self.record("relationship"); return self.relationship },
                add: { id in
                    try await self.addGate.wait()
                    self.record("add \(id)")
                    if self.failsAdd { throw Failure() }
                },
                remove: { id in self.record("remove \(id)") },
                follow: {
                    self.record("follow")
                    if self.failsFollow { throw Failure() }
                    return self.followed
                },
                create: { title in self.record("create \(title)"); return MastodonList(id: "9", title: title) }
            )
        }

        private func record(_ entry: String) {
            log.withLock { $0.append(entry) }
        }
    }

    private func makeModel(_ server: Server, isMyself: Bool = false) async -> ListMembershipModel {
        let model = ListMembershipModel(isMyself: isMyself, api: server.api, tasks: TaskScope()) {}
        await model.load()?.value
        return model
    }

    @Test func loadsListsAndMembership() async {
        let model = await makeModel(Server())

        #expect(model.phase == .loaded)
        #expect(model.lists.map(\.id) == ["1", "2"])
        #expect(model.memberListIDs == ["2"])
        #expect(model.availability == .available)
    }

    /// 押したらすぐチェックマークを変え、サーバーが受け付けたらそのまま残す。
    @Test func addsOptimistically() async throws {
        let gate = Gate()
        let server = Server(addGate: gate)
        let model = await makeModel(server)

        #expect(model.toggle("1") == .sent)
        #expect(model.memberListIDs == ["1", "2"])
        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.memberListIDs == ["1", "2"])
        #expect(server.sent.contains("add 1"))
    }

    @Test func removesMember() async throws {
        let server = Server()
        let model = await makeModel(server)

        #expect(model.toggle("2") == .sent)
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.memberListIDs.isEmpty)
        #expect(server.sent.contains("remove 2"))
    }

    /// 送れなければ、チェックマークを元に戻して知らせる。
    @Test func revertsAndReportsFailure() async throws {
        let model = await makeModel(Server(failsAdd: true))
        var failures: [String] = []
        model.onFailure = { operation, _ in failures.append(operation.failureTitle) }

        _ = model.toggle("1")
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.memberListIDs == ["2"])
        #expect(failures == ["リストに追加できませんでした"])
    }

    /// 送っている途中に押し直したら、押し直した方を最後の状態にし、先の結果で戻さない。
    @Test func laterToggleWinsOverEarlierResult() async throws {
        let gate = Gate()
        let server = Server(addGate: gate)
        let model = await makeModel(server)

        _ = model.toggle("1")
        _ = model.toggle("1")
        #expect(model.memberListIDs == ["2"])
        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.memberListIDs == ["2"])
        #expect(server.sent.suffix(2) == ["add 1", "remove 1"])
    }

    /// 送り終える前にシートを閉じてモデルを捨てても、押した足し外しは最後まで送る。
    @Test func sendingOutlivesTheSheet() async throws {
        let gate = Gate()
        let server = Server(addGate: gate)
        let parent = TaskScope()
        var model: ListMembershipModel? = ListMembershipModel(isMyself: false, api: server.api, tasks: parent.child()) {}
        await model?.load()?.value
        _ = model?.toggle("1")
        try await waitUntil { gate.waiterCount == 1 }
        model = nil
        gate.open()
        try await waitUntil { parent.runningCount == 0 }

        #expect(server.sent.contains("add 1"))
    }

    /// フォローもリクエストもしていない人は、送らずにフォローが要ることを返す。
    @Test func unfollowedNeedsFollow() async {
        let server = Server(relationship: Relationship(id: "7"))
        let model = await makeModel(server)

        #expect(model.availability == .needsFollow)
        #expect(model.toggle("1") == .needsFollow)
        #expect(model.memberListIDs == ["2"])
        #expect(!server.sent.contains { $0.hasPrefix("add") })
    }

    /// 入っているリストから外すのは、フォローしていなくてもできる。
    @Test func unfollowedCanBeRemoved() async {
        let model = await makeModel(Server(relationship: Relationship(id: "7")))

        #expect(model.toggle("2") == .sent)
    }

    /// 承認制の相手は、リクエスト中のまま足す。
    @Test func followThenAddsWhenRequested() async throws {
        let server = Server(relationship: Relationship(id: "7"), followed: Relationship(id: "7", requested: true))
        let model = await makeModel(server)
        var followed: [Relationship] = []
        model.onFollowed = { followed.append($0) }

        model.followAndAdd("1")
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(server.sent.suffix(2) == ["follow", "add 1"])
        #expect(model.memberListIDs == ["1", "2"])
        #expect(followed == [Relationship(id: "7", requested: true)])
    }

    @Test func followFailureDoesNotAdd() async throws {
        let server = Server(relationship: Relationship(id: "7"), failsFollow: true)
        let model = await makeModel(server)
        var failures = 0
        model.onFailure = { _, _ in failures += 1 }

        model.followAndAdd("1")
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(!server.sent.contains { $0.hasPrefix("add") })
        #expect(model.memberListIDs == ["2"])
        #expect(failures == 1)
        #expect(!model.isFollowing)
    }

    @Test func blockedCannotBeAdded() async {
        let model = await makeModel(Server(relationship: Relationship(id: "7", following: true, blockedBy: true)))

        #expect(model.availability == .blocked)
        #expect(model.toggle("1") == .unavailable)
    }

    /// 自分はフォローせずに足せる。関係も読まない。
    @Test func myselfIsAddedWithoutRelationship() async {
        let server = Server(relationship: Relationship(id: "7"))
        let model = await makeModel(server, isMyself: true)

        #expect(model.availability == .available)
        #expect(model.toggle("1") == .sent)
        #expect(!server.sent.contains("relationship"))
    }

    /// 作ったリストはシートの並びに足す。その人を足すのは呼んだ側に任せる。
    @Test func createAppendsList() async throws {
        let model = await makeModel(Server())

        let list = try await model.create(title: "新しい")

        #expect(list.id == "9")
        #expect(model.lists.map(\.id) == ["1", "2", "9"])
        #expect(!model.memberListIDs.contains("9"))
    }
}
