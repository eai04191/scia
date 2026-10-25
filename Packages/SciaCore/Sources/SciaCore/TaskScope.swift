/// ログインしているアカウントの画面一式や、開いているプロフィールのように、寿命のあるものが始めた処理の持ち主。
///
/// 処理はここを通して始める。終わった処理は自分で外れ、閉じると走っている処理を全部取り消し、閉じたあとは何も始めない。
/// 子の持ち主は、親を閉じたときと、子を持つものが捨てられたときに閉じる。止める処理の一覧を手で並べて保たずに、ログアウトやアカウントの切り替えで漏れなく止めるため。
@MainActor
public final class TaskScope {
    /// 同じ名前の処理がもう走っているときの扱い。
    public enum Overlap: Sendable {
        /// 前のものを取り消して始め直す。期限を待ち直すときなど。
        case replacing
        /// 走っている間は始めない。送り終える前に押し直されても、同じ要求を重ねて送らないため。
        case skippingWhileRunning
    }

    /// 閉じたか。閉じたあとは何も始めない。
    public private(set) var isClosed = false

    /// 走り終えていない処理の数。子の持ち主の分も含める。取り消した処理も、走り終えるまで数える。
    /// 子を持つものが捨てられて子が閉じたあとも、子で始めた処理は走り終えるまで数える。
    public var runningCount: Int { counter.count }

    private var tasks: [Int: Task<Void, Never>] = [:]
    private var keys: [String: Int] = [:]
    private var nextID = 0
    private var children: [WeakScope] = []
    private var closeActions: [@MainActor () -> Void] = []
    /// 走り終えていない処理の数を、親の持ち主まで届ける。処理はこれを持つので、持ち主が捨てられても走り終えたときに減らせる。
    private let counter: RunningCounter

    private var liveChildren: [TaskScope] { children.compactMap(\.scope) }

    public init() {
        counter = RunningCounter(parent: nil)
    }

    private init(parent: TaskScope) {
        counter = RunningCounter(parent: parent.counter)
    }

    isolated deinit {
        close()
    }

    /// `operation`を始める。閉じていれば始めずにnilを返す。
    @discardableResult
    public func run(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        let id = nextID
        nextID += 1
        let counter = counter
        counter.add(1)
        // メインアクターで作るので、中身は登録を終えてから走る。
        let task = Task { [weak self] in
            // 走り出す前に閉じたり始め直したりしたら、中身を動かさない。取り消しだけでは、まだ始まっていない中身は止まらないため。
            if !Task.isCancelled {
                await operation()
            }
            counter.add(-1)
            self?.finish(id)
        }
        tasks[id] = task
        return task
    }

    /// 名前を付けて`operation`を始める。同じ名前の処理が走っていれば、`overlap`に従う。始めなかったらnilを返す。
    @discardableResult
    public func run(key: String, _ overlap: Overlap, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        if let running = keys[key] {
            switch overlap {
            case .replacing:
                tasks[running]?.cancel()
            case .skippingWhileRunning:
                return nil
            }
        }
        let id = nextID
        guard let task = run(operation) else { return nil }
        keys[key] = id
        return task
    }

    /// 今走っている処理が全部終わるまで待つ。待ち始めたあとに始めた処理は待たない。子の持ち主の処理も待たない。
    /// 走っている処理の中から呼ぶと、自分の終わりを待って止まるので、持ち主の外から呼ぶ。
    public func waitForRunning() async {
        for task in tasks.values {
            await task.value
        }
    }

    /// `key`の処理が走っているか。取り消されて走り終えていないものは、走っているとみなさない。
    public func isRunning(key: String) -> Bool {
        keys[key] != nil
    }

    /// `key`の処理を取り消す。
    public func cancel(key: String) {
        guard let id = keys.removeValue(forKey: key) else { return }
        tasks[id]?.cancel()
    }

    /// 子の持ち主を作る。親を閉じたとき、または返したものを手放したときに閉じる。閉じていれば、閉じたものを返す。
    public func child() -> TaskScope {
        let child = TaskScope(parent: self)
        guard !isClosed else {
            child.close()
            return child
        }
        children.removeAll { $0.scope == nil }
        children.append(WeakScope(scope: child))
        return child
    }

    /// 閉じるときに`action`を呼ぶ。Taskでない処理（購読やタイマーなど）を、閉じたときに一緒に止めるのに使う。閉じていればすぐ呼ぶ。
    public func onClose(_ action: @escaping @MainActor () -> Void) {
        guard !isClosed else {
            action()
            return
        }
        closeActions.append(action)
    }

    /// 走っている処理と子の持ち主を全部止め、以後は何も始めない。
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        keys.removeAll()
        for task in tasks.values {
            task.cancel()
        }
        // 子は外さずに残す。取り消した処理が走り終えるまで、`runningCount`に数えるため。
        for child in liveChildren {
            child.close()
        }
        let actions = closeActions
        closeActions.removeAll()
        for action in actions {
            action()
        }
    }

    private func finish(_ id: Int) {
        tasks[id] = nil
        if let key = keys.first(where: { $0.value == id })?.key {
            keys[key] = nil
        }
    }
}

/// 走り終えていない処理の数。親の数にも足す。
@MainActor
private final class RunningCounter {
    private(set) var count = 0
    private let parent: RunningCounter?

    init(parent: RunningCounter?) {
        self.parent = parent
    }

    func add(_ change: Int) {
        count += change
        parent?.add(change)
    }
}

private struct WeakScope {
    weak var scope: TaskScope?
}
