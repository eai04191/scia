/// 写真ピッカーから届いた選択を、下書きの添付ファイルの並びに取り込む。
///
/// ピッカーは選択が変わるたびに今の選択を全部送ってくる。そのまま並びに当てると、投稿欄で並べ替えた順が上書きされるため、
/// 足したものと外したものだけを取り込み、並びは下書きの側の順番を保つ。IDはピッカーの`assetIdentifier`。
public struct MediaPickerSelection: Sendable, Equatable {
    /// 投稿欄で外したが、開いているピッカーではまだ選ばれているID。ピッカーが選択を送り直しても足し直さない。
    public private(set) var removedWhilePickerOpen: Set<String> = []

    public init() {}

    /// ピッカーの今の選択から、下書きから外すIDと、後ろに足すIDを決める。
    /// - Parameters:
    ///   - current: 下書きの添付ファイルのID。下書きの並び順。
    ///   - selected: ピッカーの今の選択。ピッカーで選んだ順。
    /// - Returns: `removed`は`current`の順、`added`は`selected`の順。
    public mutating func changes(current: [String], selected: [String]) -> (removed: [String], added: [String]) {
        let selectedSet = Set(selected)
        // ピッカーでも外されたら、もう抑える必要はない。次に選び直したら足す。
        removedWhilePickerOpen.formIntersection(selectedSet)
        let currentSet = Set(current)
        let removed = current.filter { !selectedSet.contains($0) }
        var seen: Set<String> = []
        let added = selected.filter { id in
            !currentSet.contains(id) && !removedWhilePickerOpen.contains(id) && seen.insert(id).inserted
        }
        return (removed, added)
    }

    /// 投稿欄で外した。ピッカーを開いていれば、閉じるまでピッカーからの選択で足し直さない。
    public mutating func didRemoveInDraft(_ id: String, pickerIsOpen: Bool) {
        guard pickerIsOpen else { return }
        removedWhilePickerOpen.insert(id)
    }

    /// ピッカーを閉じた。次に開くときは下書きの並びを前の選択として渡すので、抑えていたIDは要らない。
    public mutating func pickerDidClose() {
        removedWhilePickerOpen = []
    }
}
