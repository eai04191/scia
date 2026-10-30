/// バックグラウンドの時間を頼んだ数と、まだ返していない数を数える。送っている間だけ頼んでいることを、テストが確かめるのに使う。
@MainActor
final class BackgroundTimeRecorder {
    private(set) var requestedNames: [String] = []
    private var held: Set<Int> = []
    var heldCount: Int { held.count }

    private var expirations: [Int: @MainActor () -> Void] = [:]

    func request(_ name: String) -> @MainActor () -> Void {
        request(name) {}
    }

    /// `expireAll()`で、OSが与えた時間が尽きたときと同じく`onExpire`を呼ぶ。
    func request(_ name: String, onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = requestedNames.count
        requestedNames.append(name)
        held.insert(id)
        expirations[id] = onExpire
        return { [weak self] in
            self?.held.remove(id)
            self?.expirations[id] = nil
        }
    }

    /// 返していない頼みの時間を、すべて尽きさせる。
    func expireAll() {
        let pending = expirations
        expirations = [:]
        for (id, onExpire) in pending {
            held.remove(id)
            onExpire()
        }
    }
}
