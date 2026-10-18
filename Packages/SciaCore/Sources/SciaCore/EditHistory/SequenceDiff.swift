/// 差分の中で、その部分が前の版からどう変わったか。
public enum DiffChange: Equatable, Sendable {
    case unchanged
    /// 新しい版で足された。
    case inserted
    /// 前の版にあって、新しい版で消された。
    case removed
}

enum SequenceDiff {
    /// `old`から`new`への差分を、新しい版の並びに消えた要素を差し込んだ1列にして返す。
    ///
    /// 変わらない要素に挟まれた変更のまとまりの中では、消えた要素を先に、足された要素を後に並べる。
    /// 消えたものと足されたものが交互に並ぶと、どれがどれに置き換わったのか読み取れないため。
    static func merged<Element: Equatable>(_ old: [Element], _ new: [Element]) -> [(Element, DiffChange)] {
        let difference = new.difference(from: old)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }
        var result: [(Element, DiffChange)] = []
        var removed: [Element] = []
        var inserted: [Element] = []
        func flush() {
            result += removed.map { ($0, .removed) } + inserted.map { ($0, .inserted) }
            removed = []
            inserted = []
        }
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removedOffsets.contains(oldIndex) {
                removed.append(old[oldIndex])
                oldIndex += 1
            } else if newIndex < new.count, insertedOffsets.contains(newIndex) {
                inserted.append(new[newIndex])
                newIndex += 1
            } else {
                flush()
                result.append((new[newIndex], .unchanged))
                oldIndex += 1
                newIndex += 1
            }
        }
        flush()
        return result
    }
}
