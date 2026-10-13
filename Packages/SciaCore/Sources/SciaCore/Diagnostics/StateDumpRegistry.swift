/// 画面やモデルが、違和感レポートに含める状態の書き出し方を登録する場所。
@MainActor
public final class StateDumpRegistry {
    private struct Entry {
        let name: String
        let dump: @MainActor () -> String?
    }

    private var entries: [Entry] = []

    public init() {}

    /// `owner`が解放されると、その登録は使われなくなる。`dump`は`owner`を引数で受け取るので、強参照で捕まえなくてよい。
    public func register<Owner: AnyObject>(_ name: String, owner: Owner, dump: @escaping @MainActor (Owner) -> String) {
        entries.append(Entry(name: name) { [weak owner] in owner.map(dump) })
    }

    /// 登録順に、現存するものの状態を書き出す。
    public func dumpAll() -> [StateDump] {
        var dumps: [StateDump] = []
        var alive: [Entry] = []
        for entry in entries {
            guard let text = entry.dump() else { continue }
            dumps.append(StateDump(name: entry.name, text: text))
            alive.append(entry)
        }
        entries = alive
        return dumps
    }
}
