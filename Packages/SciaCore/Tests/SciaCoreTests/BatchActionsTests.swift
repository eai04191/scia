import Foundation
import SciaCore
import SciaTesting
import Testing

/// まとめて行う操作の、選ぶ順番、ブーストの送り方、共有に渡すものを確かめる。決まりはdocs/batch-actions.mdにある。
@MainActor
struct BatchActionsTests {
    private struct Failure: Error {}

    private let me = "9"

    /// 送ったものを、送る処理の中から書き足す。
    @MainActor private final class Log {
        var sent: [String] = []
        var failsReblog = true
    }

    private func status(_ id: String, content: String = "<p>本文</p>", reblogged: Bool = false, visibility: Status.Visibility = .public, authorID: String = "2", media: [MediaAttachment] = [], reblog: Status? = nil) -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: authorID, username: "bob", acct: "bob", displayName: "Bob", avatar: nil),
            content: content,
            spoilerText: "",
            url: nil,
            mediaAttachments: media,
            visibility: visibility,
            reblogged: reblogged,
            reblog: reblog
        )
    }

    private func attachment(_ name: String, type: MediaAttachment.Kind = .image) -> MediaAttachment {
        MediaAttachment(id: name, type: type, url: URL(string: "https://files.example/\(name)"), previewUrl: nil)
    }

    // MARK: 選ぶ順番

    /// 選んだ順に番号を付け、外したら後ろの番号を詰める。
    @Test func selectionNumbersInOrderAndClosesGaps() {
        var selection = OrderedSelection<String>()
        selection.toggle("a")
        selection.toggle("b")
        selection.toggle("c")
        #expect(selection.number(of: "c") == 3)

        selection.toggle("a")

        #expect(selection.ids == ["b", "c"])
        #expect(selection.number(of: "b") == 1)
        #expect(selection.number(of: "c") == 2)
        #expect(selection.number(of: "a") == nil)
    }

    /// 一覧から消えた行を外し、残りの番号を詰める。
    @Test func selectionDropsRemovedRows() {
        var selection = OrderedSelection(["a", "b", "c"])

        #expect(selection.keep { $0 != "b" })

        #expect(selection.ids == ["a", "c"])
        #expect(selection.number(of: "c") == 2)
        #expect(!selection.keep { _ in true })
    }

    // MARK: ブーストの送り方

    /// ブースト済みの投稿は付け直し、ブーストできない投稿（他人のフォロワー限定、個別）は飛ばす。同じ投稿は先に選んだほうの順番で1度だけ送る。
    @Test func planReblogsAgainSkipsUnreblogableAndDeduplicates() {
        let original = status("1")
        let plan = BatchReblogPlan(statuses: [
            status("2", reblogged: true),
            original,
            status("3", visibility: .private),
            status("4", visibility: .direct),
            status("5", reblog: original),
            status("6", visibility: .private, authorID: me),
        ], myAccountID: me)

        #expect(plan.steps.map(\.status.displayed.id) == ["2", "1", "6"])
        #expect(plan.steps.map(\.reblogsAgain) == [true, false, false])
        #expect(plan.reblogAgainCount == 1)
        #expect(plan.skippedCount == 2)
    }

    /// 選んだ順に、前の応答を待ってから次を送り、ブースト済みの投稿は取り消してから付ける。1件ごとに間隔をあけ、最初の1件は待たない。
    @Test func runSendsInOrderWaitingForEachResponseAndInterval() async throws {
        let clock = TestClock()
        var sent: [String] = []
        let gate = Gate()
        let plan = BatchReblogPlan(statuses: [status("1"), status("2", reblogged: true), status("3")], myAccountID: me)
        let run = BatchReblog(plan: plan, interval: { .seconds(1) }, clock: clock) { status in
            sent.append("unreblog \(status.id)")
        } reblog: { status in
            sent.append("reblog \(status.id)")
            if status.id == "1" { try await gate.wait() }
        }

        let outcome = Task { await run.run() }
        try await waitUntil { sent == ["reblog 1"] }
        // 応答を待っている間は、次を送らない。
        #expect(clock.sleeperCount == 0)
        gate.open()
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(sent == ["reblog 1"])
        #expect(run.completedCount == 1)

        clock.advance(by: .seconds(1))
        try await waitUntil { clock.sleeperCount == 1 && sent.count == 3 }
        #expect(sent == ["reblog 1", "unreblog 2", "reblog 2"])

        clock.advance(by: .seconds(1))
        guard case .finished = await outcome.value else {
            Issue.record("全部送り終えていない")
            return
        }
        #expect(sent == ["reblog 1", "unreblog 2", "reblog 2", "reblog 3"])
        #expect(run.completedCount == 3)
    }

    /// 失敗したらそこで止め、もう一度走らせると失敗した投稿から続ける。取り消したあとのブーストで失敗した投稿は、続きでは付けるだけにする。
    @Test func failureStopsAndRetryResumesFromFailedStep() async throws {
        let log = Log()
        let plan = BatchReblogPlan(statuses: [status("1"), status("2", reblogged: true), status("3")], myAccountID: me)
        let run = BatchReblog(plan: plan, interval: { .zero }, clock: TestClock()) { status in
            log.sent.append("unreblog \(status.id)")
        } reblog: { status in
            if status.id == "2", log.failsReblog { throw Failure() }
            log.sent.append("reblog \(status.id)")
        }

        guard case .failed(let index, _) = await run.run() else {
            Issue.record("失敗で止まっていない")
            return
        }
        #expect(index == 1)
        #expect(log.sent == ["reblog 1", "unreblog 2"])
        #expect(run.completedCount == 1)

        log.failsReblog = false
        guard case .finished = await run.run() else {
            Issue.record("続きを送り終えていない")
            return
        }
        #expect(log.sent == ["reblog 1", "unreblog 2", "reblog 2", "reblog 3"])
    }

    /// 取り消した直後のブーストが、サーバーが前のブーストを消し終えていないことで断られたら、間をおいて送り直す。付けるときは取り消したあとの状態から送る。
    /// 送り直しを使い切ったら失敗にする。
    @Test func reblogAfterUnreblogRetriesWhileRemovalIsPending() async throws {
        let clock = TestClock()
        let log = Log()
        var rejections = 2
        let plan = BatchReblogPlan(statuses: [status("1", reblogged: true)], myAccountID: me)
        let run = BatchReblog(plan: plan, interval: { .zero }, clock: clock, isRemovalPending: { $0 is Failure }, removalRetryDelays: [.seconds(1), .seconds(2)]) { status in
            log.sent.append("unreblog \(status.id)")
        } reblog: { status in
            log.sent.append("reblog \(status.id) reblogged=\(status.reblogged)")
            if rejections > 0 {
                rejections -= 1
                throw Failure()
            }
        }

        let outcome = Task { await run.run() }
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        try await waitUntil { clock.sleeperCount == 1 && log.sent.count == 3 }
        clock.advance(by: .seconds(2))
        guard case .finished = await outcome.value else {
            Issue.record("送り直して済んでいない")
            return
        }
        #expect(log.sent == ["unreblog 1", "reblog 1 reblogged=false", "reblog 1 reblogged=false", "reblog 1 reblogged=false"])
    }

    /// 選んでから送るまでの間にほかの一覧でブーストした投稿も、送る直前の状態で、取り消してから付け直す。
    /// 選んだときの投稿のままブーストすると、Mastodonが前のブーストを返し、選んだ順に並ばないため。
    @Test func postBoostedAfterPlanningIsRebloggedAgain() async throws {
        let log = Log()
        var boostedElsewhere: Set<String> = []
        let plan = BatchReblogPlan(statuses: [status("1"), status("2")], myAccountID: me)
        let run = BatchReblog(plan: plan, interval: { .zero }, clock: TestClock(), isReblogged: { boostedElsewhere.contains($0.id) || $0.reblogged }) { status in
            log.sent.append("unreblog \(status.id)")
        } reblog: { status in
            log.sent.append("reblog \(status.id)")
            // 1件目を送っている間に、2件目をほかの一覧でブーストした。
            if status.id == "1" { boostedElsewhere.insert("2") }
        }

        guard case .finished = await run.run() else {
            Issue.record("送り終えていない")
            return
        }
        #expect(log.sent == ["reblog 1", "unreblog 2", "reblog 2"])
    }

    /// 受け付けたブーストを覚え、選んだときの投稿より新しい状態を答える。迷ったときはブースト済みとみなす。
    @Test func interactionsRememberSettledReblog() async throws {
        let original = status("1")
        let interactions = StatusInteractions(operations: StatusInteractions.Operations(
            favourite: { _ in throw Failure() },
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in original.settingReblogged(true) },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        )) { _, _ in }
        #expect(!interactions.mayBeReblogged(original))

        #expect(try await interactions.toggle(.reblog, on: original))

        #expect(interactions.mayBeReblogged(original))
        #expect(interactions.mayBeReblogged(status("2", reblogged: true)))
    }

    /// 走っている間にもう一度走らせても、重ねて送らない。失敗のチップを続けて押したときに、同じ投稿へ2本で送らないため。
    @Test func runDoesNotOverlap() async throws {
        let gate = Gate()
        let log = Log()
        let plan = BatchReblogPlan(statuses: [status("1")], myAccountID: me)
        let run = BatchReblog(plan: plan, interval: { .zero }, clock: TestClock()) { _ in } reblog: { status in
            log.sent.append("reblog \(status.id)")
            try await gate.wait()
        }

        let first = Task { await run.run() }
        try await waitUntil { gate.waiterCount == 1 }
        #expect(run.isRunning)
        #expect(await run.run().isAlreadyRunning)
        gate.open()
        guard case .finished = await first.value else {
            Issue.record("送り終えていない")
            return
        }
        #expect(log.sent == ["reblog 1"])
        #expect(!run.isRunning)
    }

    /// セッションを閉じて呼んだタスクが取り消されたら、間隔の待ちもやめて止める。
    @Test func cancellingRunStopsWaitingForInterval() async throws {
        let clock = TestClock()
        let plan = BatchReblogPlan(statuses: [status("1"), status("2")], myAccountID: me)
        let run = BatchReblog(plan: plan, interval: { .seconds(5) }, clock: clock) { _ in } reblog: { _ in }

        let task = Task { await run.run() }
        try await waitUntil { clock.sleeperCount == 1 }
        task.cancel()

        guard case .stopped = await task.value else {
            Issue.record("止まっていない")
            return
        }
        #expect(clock.sleeperCount == 0)
        #expect(run.completedCount == 1)
    }

    /// 止めたら、間隔を待っている途中でも次を送らずに終える。済んだ分はそのまま残す。
    @Test func stopEndsBeforeNextStep() async throws {
        let clock = TestClock()
        var sent: [String] = []
        let plan = BatchReblogPlan(statuses: [status("1"), status("2")], myAccountID: me)
        let run = BatchReblog(plan: plan, interval: { .seconds(1) }, clock: clock) { _ in } reblog: { status in
            sent.append(status.id)
        }

        let outcome = Task { await run.run() }
        try await waitUntil { clock.sleeperCount == 1 }
        run.stop()

        guard case .stopped = await outcome.value else {
            Issue.record("止まっていない")
            return
        }
        #expect(sent == ["1"])
        #expect(run.completedCount == 1)
    }

    /// まとめてブーストで付け直すとき、取り消しの向きを決めて送る。失敗したら元の状態に戻す。
    @Test func interactionsSetSendsGivenDirectionAndRestoresOnFailure() async throws {
        var shown = status("1", reblogged: true)
        var calls: [String] = []
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
        )) { _, transform in
            shown = transform(shown)
            calls.append(shown.reblogged ? "on" : "off")
        }

        await #expect(throws: Failure.self) { try await interactions.set(.reblog, to: true, on: shown) }

        // ブースト済みのまま付ける向きを送り、失敗しても取り消した状態にはしない。
        #expect(calls == ["on", "on"])
        #expect(shown.reblogged)
    }

    // MARK: 共有に渡すもの

    /// 本文は選んだ順に空行でつなぎ、本文のない投稿は飛ばす。メディアは選んだ順に、投稿ごとに添付ファイルの順で並べ、URLのないものは除く。
    @Test func sharePayloadJoinsTextsAndOrdersMedia() throws {
        let processing = MediaAttachment(id: "p", type: .video, url: nil, previewUrl: nil)
        let first = status("1", content: "<p>一つ目</p><p>二段落</p>", media: [attachment("a.png"), attachment("b.mp4", type: .video)])
        let mediaOnly = status("2", content: "", media: [processing, attachment("c.png")])
        let third = status("3", content: "<p>三つ目 :blob:</p>")

        let payload = BatchSharePayload(statuses: [third, first, mediaOnly, status("4", reblog: third)])

        // 1件の中の段落は「テキストをコピー」と同じ形のまま、投稿と投稿の間を空行でつなぐ。
        let firstText = try #require(StatusMenuTree.plainText(of: first))
        #expect(payload.text == "三つ目 :blob:\n\n" + firstText)
        #expect(payload.media.map(\.url.lastPathComponent) == ["a.png", "b.mp4", "c.png"])
        #expect(payload.media.map(\.kind) == [.image, .video, .image])
    }

    /// 本文のある投稿がなければ、文章を渡さない。
    @Test func sharePayloadHasNoTextWithoutBodies() {
        let payload = BatchSharePayload(statuses: [status("1", content: "<p> </p>", media: [attachment("a.png")])])
        #expect(payload.text == nil)
        #expect(payload.media.count == 1)
    }

    /// メディアを選んだ順に1つずつ落とし、全体の進み具合を渡す。落とせなければそこで投げ、残りは落とさない。
    @Test func downloadFetchesInOrderAndStopsOnFailure() async throws {
        let targets = try ["a", "b", "c"].map { MediaTransfers.Target(url: try #require(URL(string: "https://files.example/\($0)")), kind: .image, subject: nil) }
        var fetched: [String] = []
        var progress: [Double] = []

        let files = try await BatchShareDownload.fetchAll(targets, fetch: { url, onProgress in
            fetched.append(url.lastPathComponent)
            onProgress(0.5)
            return URL(fileURLWithPath: "/tmp/\(url.lastPathComponent)")
        }, onProgress: { _, fraction in progress.append(fraction) })

        #expect(files.map(\.lastPathComponent) == ["a", "b", "c"])
        #expect(progress.map { ($0 * 6).rounded() } == [1, 2, 3, 4, 5, 6])

        fetched = []
        await #expect(throws: Failure.self) {
            _ = try await BatchShareDownload.fetchAll(targets, fetch: { url, _ in
                fetched.append(url.lastPathComponent)
                if url.lastPathComponent == "b" { throw Failure() }
                return url
            }, onProgress: { _, _ in })
        }
        #expect(fetched == ["a", "b"])
    }
}
