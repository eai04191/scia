import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct TaskScopeTests {
    /// 正常に終わった処理は、閉じるまで溜まらずに外れる。
    @Test func finishedTaskLeaves() async throws {
        let scope = TaskScope()
        let gate = Gate()
        scope.run { try? await gate.wait() }
        #expect(scope.runningCount == 1)
        gate.open()
        try await waitUntil { scope.runningCount == 0 }
    }

    /// 閉じると走っている処理を取り消し、以後は何も始めない。
    @Test func closeCancelsAndRefusesNewWork() async throws {
        let scope = TaskScope()
        let gate = Gate()
        var cancelled = false
        scope.run {
            do { try await gate.wait() } catch { cancelled = true }
        }
        try await waitUntil { gate.waiterCount == 1 }
        scope.close()
        try await waitUntil { scope.runningCount == 0 }
        #expect(cancelled)

        var ran = false
        #expect(scope.run { ran = true } == nil)
        #expect(scope.runningCount == 0)
        #expect(!ran)
    }

    /// 親を閉じると、子の処理も止まる。
    @Test func closingParentClosesChildren() async throws {
        let parent = TaskScope()
        let child = parent.child()
        let grandchild = child.child()
        let gate = Gate()
        child.run { try? await gate.wait() }
        grandchild.run { try? await gate.wait() }
        try await waitUntil { gate.waiterCount == 2 }
        #expect(parent.runningCount == 2)

        parent.close()
        #expect(child.isClosed)
        #expect(grandchild.isClosed)
        try await waitUntil { parent.runningCount == 0 && gate.waiterCount == 0 }
        #expect(grandchild.run {} == nil)
    }

    /// 閉じたあとも、子の取り消した処理が走り終えるまでは数える。止めたあとに何も起きないことを、走り終えたかで確かめるため。
    @Test func closedParentCountsChildWorkUntilItEnds() async throws {
        let parent = TaskScope()
        let child = parent.child()
        let gate = Gate()
        child.run { try? await gate.wait() }
        parent.close()
        // 取り消した処理は、まだ戻り切っていない。
        #expect(parent.runningCount == 1)
        try await waitUntil { parent.runningCount == 0 }
        _ = child
    }

    /// 始めた直後、走り出す前に閉じたら、中身を動かさない。取り消しだけでは、まだ始まっていない処理の中身は止まらないため。
    @Test func closingBeforeStartSkipsOperation() async throws {
        let scope = TaskScope()
        var ran = false
        let task = scope.run { ran = true }
        scope.close()
        await task?.value
        #expect(!ran)
        #expect(scope.runningCount == 0)
    }

    /// 前のものを取り消して始め直したら、走り出す前に取り消された前のものは動かさない。
    @Test func replacedBeforeStartSkipsOperation() async throws {
        let scope = TaskScope()
        var ran: [String] = []
        let first = scope.run(key: "mute:1", .replacing) { ran.append("first") }
        let second = scope.run(key: "mute:1", .replacing) { ran.append("second") }
        await first?.value
        await second?.value
        #expect(ran == ["second"])
    }

    /// 子を持つものが捨てられても、子の取り消した処理が走り終えるまでは、親が数える。
    @Test func releasedChildWorkIsCountedUntilItEnds() async throws {
        let parent = TaskScope()
        let gate = Gate()
        let started = Gate()
        var child: TaskScope? = parent.child()
        child?.run {
            started.open()
            // 取り消しを受けても、門が開くまで戻らない後始末。
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    Task { try? await gate.wait(); continuation.resume() }
                }
            } onCancel: {}
        }
        try await started.wait()
        child = nil
        #expect(parent.runningCount == 1)
        gate.open()
        try await waitUntil { parent.runningCount == 0 }
    }

    /// 閉じた親から作った子は、閉じたまま作る。
    @Test func childOfClosedScopeIsClosed() {
        let parent = TaskScope()
        parent.close()
        #expect(parent.child().isClosed)
    }

    /// 子を持つもの（閉じたプロフィールなど）が捨てられたら、子の処理を止める。
    @Test func releasingChildCancelsItsWork() async throws {
        let parent = TaskScope()
        let gate = Gate()
        var child: TaskScope? = parent.child()
        child?.run { try? await gate.wait() }
        try await waitUntil { gate.waiterCount == 1 }
        child = nil
        try await waitUntil { gate.waiterCount == 0 && parent.runningCount == 0 }
    }

    /// 走っている間は、同じ名前の処理を重ねて始めない。走り終えたら、また始められる。
    @Test func skipsWhileRunning() async throws {
        let scope = TaskScope()
        let gate = Gate()
        var count = 0
        let first = scope.run(key: "delete:1", .skippingWhileRunning) {
            count += 1
            try? await gate.wait()
        }
        #expect(first != nil)
        #expect(scope.run(key: "delete:1", .skippingWhileRunning) { count += 1 } == nil)
        #expect(scope.isRunning(key: "delete:1"))
        gate.open()
        await first?.value
        #expect(!scope.isRunning(key: "delete:1"))
        await scope.run(key: "delete:1", .skippingWhileRunning) { count += 1 }?.value
        #expect(count == 2)
    }

    /// 前のものを取り消して始め直す。取り消した処理が後から終わっても、新しいものの名前は残る。
    @Test func replacingCancelsPrevious() async throws {
        let scope = TaskScope()
        let firstGate = Gate()
        let secondGate = Gate()
        var cancelled = false
        let first = scope.run(key: "mute:1", .replacing) {
            do { try await firstGate.wait() } catch { cancelled = true }
        }
        try await waitUntil { firstGate.waiterCount == 1 }
        scope.run(key: "mute:1", .replacing) { try? await secondGate.wait() }
        await first?.value
        #expect(cancelled)
        #expect(scope.isRunning(key: "mute:1"))
        #expect(scope.runningCount == 1)
        secondGate.open()
        try await waitUntil { scope.runningCount == 0 }
        #expect(!scope.isRunning(key: "mute:1"))
    }

    /// 走っている処理が終わるまで待つ。
    @Test func waitsForRunning() async throws {
        let scope = TaskScope()
        let gate = Gate()
        var finished = false
        scope.run {
            try? await gate.wait()
            finished = true
        }
        let waiting = Task { await scope.waitForRunning() }
        try await waitUntil { gate.waiterCount == 1 }
        #expect(!finished)
        gate.open()
        await waiting.value
        #expect(finished)
    }

    /// 閉じるときに、Taskでない処理も止める。閉じたあとに登録したものはすぐ呼ぶ。
    @Test func closeActionsRunOnce() {
        let scope = TaskScope()
        var calls = 0
        scope.onClose { calls += 1 }
        scope.close()
        scope.close()
        #expect(calls == 1)
        scope.onClose { calls += 1 }
        #expect(calls == 2)
    }
}
