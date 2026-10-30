/// バックグラウンドの時間を頼んだ数と、まだ返していない数を数える。送っている間だけ頼んでいることを、テストが確かめるのに使う。
@MainActor
final class BackgroundTimeRecorder {
    private(set) var requestedNames: [String] = []
    private var held: Set<Int> = []
    var heldCount: Int { held.count }

    func request(_ name: String) -> @MainActor () -> Void {
        let id = requestedNames.count
        requestedNames.append(name)
        held.insert(id)
        return { [weak self] in self?.held.remove(id) }
    }
}
