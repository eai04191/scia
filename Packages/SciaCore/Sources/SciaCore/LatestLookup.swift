/// 押してから相手を探して開くような、待ってから画面を動かす操作の入口。同じ入口に通した操作は、後から始めたものだけを生かす。
///
/// 待っている間に次の操作を始めたら、前のものは止め、前のものの結果は届いても渡さない。待っている間も、ほかの操作は止めない。
/// 届いたときには`isStillWanted`で、結果を使う先（押した画面など）がまだあるかを確かめ、なければ結果も失敗も渡さない。
/// 待つのが長引いたら`onSlowChange`で知らせる。選び直しても待っていることに変わりはないので、知らせは引っ込めず、知らせるまでの時間も数え直さない。
@MainActor
public final class LatestLookup {
    /// 待ち始めてから`slowAfter`が過ぎても、まだ待っているか。
    public private(set) var isSlow = false {
        didSet {
            if isSlow != oldValue { onSlowChange?(isSlow) }
        }
    }

    /// `isSlow`が変わったときに呼ぶ。チップを出し入れするのに使う。
    public var onSlowChange: ((Bool) -> Void)?

    public var isWaiting: Bool { current != nil }

    private let clock: any Clock<Duration>
    private let slowAfter: @MainActor () -> Duration?
    private var current: (id: Int, task: Task<Void, Never>)?
    private var nextID = 0
    /// 続けて待っている間の、`isSlow`にするまでの待ち。選び直しても作り直さない。
    private var slowTimer: Task<Void, Never>?

    /// - Parameters:
    ///   - clock: 長引いたかを測る。テストでは手で進める時計を渡す。
    ///   - slowAfter: 待ち始めてから長引いたとみなすまでの時間。nilなら知らせない。チューニングで変えた値を使うよう、待ち始めるたびに読む。
    public init(clock: any Clock<Duration> = SystemTime.clock, slowAfter: @escaping @MainActor () -> Duration?) {
        self.clock = clock
        self.slowAfter = slowAfter
    }

    /// `work`を待ち、結果を`completion`に渡す。待っているものがあれば止める。
    public func start<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value,
        isStillWanted: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (Result<Value, any Error>) -> Void
    ) {
        current?.task.cancel()
        let id = nextID
        nextID += 1
        if slowTimer == nil, let delay = slowAfter() {
            let clock = clock
            slowTimer = Task { [weak self] in
                try? await clock.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.isSlow = true
            }
        }
        let task = Task { [weak self] in
            let result: Result<Value, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            // 止められたものは、止めた側が後を受け持つ。
            guard let self, current?.id == id else { return }
            finish()
            guard isStillWanted() else { return }
            completion(result)
        }
        current = (id, task)
    }

    /// 待っているものを止め、結果を渡さない。
    public func cancel() {
        current?.task.cancel()
        finish()
    }

    private func finish() {
        current = nil
        slowTimer?.cancel()
        slowTimer = nil
        isSlow = false
    }
}
