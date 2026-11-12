/// 応答を待つ操作が長引いているかを見る。押しても応答が届くまで画面が変わらない操作で、待っていることをチップで知らせるのに使う。
///
/// 待つ操作のどれかが`slowAfter`より長引いたら`isSlow`にし、長引いた操作がなくなったら戻す。
/// すぐ終わった操作でチップが一瞬だけ出入りしないよう、待ち始めてすぐには`isSlow`にしない。
@MainActor
public final class SlowActivity {
    public private(set) var isSlow = false {
        didSet {
            if isSlow != oldValue { onSlowChange?(isSlow) }
        }
    }

    /// `isSlow`が変わったときに呼ぶ。チップを出し入れするのに使う。
    public var onSlowChange: ((Bool) -> Void)?

    private let clock: any Clock<Duration>
    private let slowAfter: @MainActor () -> Duration
    /// 待っている操作と、その操作を長引いたとみなすまでの待ち。
    private var timers: [Int: Task<Void, Never>] = [:]
    private var slowIDs: Set<Int> = []
    private var nextID = 0

    /// - Parameters:
    ///   - clock: 長引いたかを測る。テストでは手で進める時計を渡す。
    ///   - slowAfter: 待ち始めてから長引いたとみなすまでの時間。チューニングで変えた値を使うよう、待ち始めるたびに読む。
    public init(clock: any Clock<Duration> = SystemTime.clock, slowAfter: @escaping @MainActor () -> Duration) {
        self.clock = clock
        self.slowAfter = slowAfter
    }

    /// 待っている操作の数。
    public var waitingCount: Int { timers.count }

    /// `work`を待つ間を、待っている操作として数える。投げても取り消されても、終わったら数えるのをやめる。
    public func track<Value: Sendable>(_ work: @Sendable () async throws -> Value) async rethrows -> Value {
        let id = nextID
        nextID += 1
        let delay = slowAfter()
        timers[id] = Task(.withoutRequests) { [weak self, clock] in
            guard (try? await clock.sleep(for: delay)) != nil, let self, timers[id] != nil else { return }
            slowIDs.insert(id)
            isSlow = true
        }
        defer {
            timers.removeValue(forKey: id)?.cancel()
            slowIDs.remove(id)
            isSlow = !slowIDs.isEmpty
        }
        return try await work()
    }
}
