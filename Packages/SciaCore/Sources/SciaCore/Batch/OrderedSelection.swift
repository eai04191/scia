/// タイムラインで順番を付けて選んだもの。選んだ順に持ち、外したら後ろの番号を詰める。決まりはdocs/batch-actions.mdの「選んでいる間」にある。
public struct OrderedSelection<ID: Hashable & Sendable>: Sendable, Equatable {
    /// 選んだ順。
    public private(set) var ids: [ID] = []

    public init(_ ids: [ID] = []) {
        var seen: Set<ID> = []
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }

    public func contains(_ id: ID) -> Bool {
        ids.contains(id)
    }

    /// 選んだ順の番号。1から数える。選んでいなければnil。
    public func number(of id: ID) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    /// 選んでいなければ最後に足し、選んでいれば外す。
    public mutating func toggle(_ id: ID) {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
    }

    /// `isKept`に当たるものだけを残す。タイムラインから消えた行を外すのに使う。外したものがあればtrue。
    @discardableResult
    public mutating func keep(where isKept: (ID) -> Bool) -> Bool {
        let before = ids.count
        ids.removeAll { !isKept($0) }
        return ids.count != before
    }
}
