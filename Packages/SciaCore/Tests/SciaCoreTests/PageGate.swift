/// 読み込みの応答を止めておき、止めている間にほかの操作をしてから返すための道具。読み始めたあとに起きた変化を試すのに使う。
actor PageGate<Value: Sendable> {
    private let value: Value
    private var holds = false
    private var requested = false
    private var pending: CheckedContinuation<Value, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    init(_ value: Value) {
        self.value = value
    }

    /// 以後の読み込みを、`release()`まで止める。
    func hold() {
        holds = true
    }

    func fetch() async -> Value {
        guard holds else { return value }
        requested = true
        observer?.resume()
        observer = nil
        return await withCheckedContinuation { pending = $0 }
    }

    /// 止めた読み込みが始まるまで待つ。
    func waitForRequest() async {
        guard !requested else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        pending?.resume(returning: value)
        pending = nil
    }
}
