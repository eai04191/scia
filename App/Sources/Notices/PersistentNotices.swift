import SciaCore

/// 1つの画面で出たままになっている知らせを、出た順に持つ。チップは1枚にするため、`chipNotice`で1件を選んで出す。
/// 決まりはdocs/notices.mdの「チップ」にある。
struct PersistentNotices {
    /// 知らせの出どころ。出どころごとに1件だけ持つ。
    enum Slot {
        /// 投稿欄から開いたビューアの、アップロードや代替テキストの送信の状態。
        case draft
        /// 共有や保存のために落としている途中。
        case download
    }

    private var entries: [(slot: Slot, notice: Notice)] = []

    var isEmpty: Bool { entries.isEmpty }

    func notice(in slot: Slot) -> Notice? {
        entries.first { $0.slot == slot }?.notice
    }

    /// `slot`の知らせを置き換える。nilなら外す。同じ知らせ（同じid）の書き換えなら、出た順の位置を保つ。
    mutating func set(_ notice: Notice?, in slot: Slot) {
        if let index = entries.firstIndex(where: { $0.slot == slot }) {
            if let notice, entries[index].notice.id == notice.id {
                entries[index].notice = notice
                return
            }
            entries.remove(at: index)
        }
        if let notice {
            entries.append((slot, notice))
        }
    }

    /// チップに出す1件。失敗を優先し、次に処理の途中、その中では新しいものを選ぶ。
    /// 2件以上なら残りの件数を添え、押すと`showAll`で「最近の失敗」の一覧を開く。
    /// - Parameter showAll: nilなら一覧を開けない画面なので、選んだ知らせの続きを出す。
    func chipNotice(showAll: (@MainActor () -> Void)?) -> Notice? {
        guard let (chosen, others) = PersistentNoticeChoice.choose(entries.map(\.notice), isFailure: { $0.kind == .failure }) else { return nil }
        var notice = chosen
        notice.additionalCount = others
        if others > 0, let showAll {
            notice.action = .disclosure(hint: "最近の失敗の一覧を開きます。", handler: showAll)
        }
        return notice
    }
}
