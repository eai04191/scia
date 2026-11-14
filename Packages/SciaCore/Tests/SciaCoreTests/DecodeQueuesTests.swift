import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

struct DecodeQueuesTests {
    /// 展開の代わりに、開けるまでキューを止めておく処理。実際の時間に頼らずに、展開が走っている最中を作る。
    private final class Blocker: Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let started = Mutex(0)

        var startedCount: Int { started.withLock { $0 } }

        func body() {
            started.withLock { $0 += 1 }
            semaphore.wait()
        }

        func open(_ count: Int) {
            (0..<count).forEach { _ in semaphore.signal() }
        }
    }

    private func start(_ work: DecodeWork, on queues: DecodeQueues, blocker: Blocker) -> Task<Void, Never> {
        Task { await queues.run(work, qos: .default) { blocker.body() } }
    }

    /// コマは後半のキューだけが取る。いくつ並んでも前半は空いていて、1枚の画像はすぐに展開できる。
    @Test func framesNeverOccupyImageQueues() async throws {
        let queues = DecodeQueues(count: 6)
        let blocker = Blocker()
        let frames = (0..<6).map { _ in start(.frames, on: queues, blocker: blocker) }
        try await waitUntil { queues.state() == "decodeQueues busy: 3 waiting images: 0 frames: 3" && blocker.startedCount >= 3 }

        let decoded = await queues.run(.image, qos: .default) { "image" }

        #expect(decoded == "image")
        blocker.open(6)
        for task in frames { await task.value }
        // 展開の結果を返してから、キューを空いたことにするので、空くまで待つ。
        try await waitUntil { queues.state() == "decodeQueues busy: 0 waiting images: 0 frames: 0" }
    }

    /// コマがなければ、1枚の画像は全部のキューを使う。
    @Test func imagesUseAllQueuesWithoutFrames() async throws {
        let queues = DecodeQueues(count: 4)
        let blocker = Blocker()

        let images = (0..<4).map { _ in start(.image, on: queues, blocker: blocker) }

        try await waitUntil { queues.state() == "decodeQueues busy: 4 waiting images: 0 frames: 0" && blocker.startedCount >= 4 }
        blocker.open(4)
        for task in images { await task.value }
    }

    /// 空いたキューは、先に並んだコマより、あとから並んだ1枚の画像を先に取る。
    /// コマも取れる後半のキューだけを空け、同じキューで取る順を見る。両方を空けると、別のキューで走る順は決まらない。
    @Test func freedQueueTakesImageBeforeFrames() async throws {
        let queues = DecodeQueues(count: 2)
        let first = Blocker()
        let second = Blocker()
        let order = Mutex<[String]>([])
        // 空いたキューは前から使うので、1つ目は前半のキュー、2つ目は後半のキューで走る。
        let firstTask = start(.image, on: queues, blocker: first)
        try await waitUntil { first.startedCount >= 1 }
        let secondTask = start(.image, on: queues, blocker: second)
        try await waitUntil { second.startedCount >= 1 }
        let frames = Task { await queues.run(.frames, qos: .default) { order.withLock { $0.append("frames") } } }
        try await waitUntil { queues.state() == "decodeQueues busy: 2 waiting images: 0 frames: 1" }
        let image = Task { await queues.run(.image, qos: .default) { order.withLock { $0.append("image") } } }
        try await waitUntil { queues.state() == "decodeQueues busy: 2 waiting images: 1 frames: 1" }

        second.open(1)

        await secondTask.value
        await image.value
        await frames.value
        #expect(order.withLock { $0 } == ["image", "frames"])
        first.open(1)
        await firstTask.value
    }

    /// 長い展開が走っているキューに、あとの展開を決め打ちで積まない。ほかのキューが空いたら、そこで走る。
    @Test func waitingImageRunsOnWhicheverQueueFreesFirst() async throws {
        let queues = DecodeQueues(count: 2)
        let slow = Blocker()
        let fast = Blocker()
        let slowTask = start(.image, on: queues, blocker: slow)
        try await waitUntil { slow.startedCount >= 1 }
        let fastTask = start(.image, on: queues, blocker: fast)
        try await waitUntil { fast.startedCount >= 1 }
        let waiting = Task { await queues.run(.image, qos: .default) { "waiting" } }
        try await waitUntil { queues.state() == "decodeQueues busy: 2 waiting images: 1 frames: 0" }

        fast.open(1)

        #expect(await waiting.value == "waiting")
        slow.open(1)
        await slowTask.value
        await fastTask.value
    }

    /// キューが1本しかなければ、分けずに、コマも1枚の画像も同じキューで走らせる。
    @Test func singleQueueServesBoth() async throws {
        let queues = DecodeQueues(count: 1)

        let frames = await queues.run(.frames, qos: .default) { "frames" }
        let image = await queues.run(.image, qos: .default) { "image" }

        #expect([frames, image] == ["frames", "image"])
        try await waitUntil { queues.state() == "decodeQueues busy: 0 waiting images: 0 frames: 0" }
    }
}
