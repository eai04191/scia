import SciaCore

/// チップの列に出たままになっているアプリ内通知を、出た順に持つ。チップは1枚にするため、`chipNotice`で1件を選んで出す。
/// 決まりはdocs/notices.mdの「チップ」にある。
struct PersistentNotices {
    /// アプリ内通知の出どころ。出どころごとに1件だけ持つ。
    enum Slot: CaseIterable {
        /// 前に出ている画面の中だけで意味のあるもの。投稿欄から開いたビューアの、アップロードや代替テキストの送信の状態など。
        case screen
        /// 共有や保存のために落としている途中。ビューアを閉じても続くため、アプリ全体のもの。
        case download
        /// リンクのメニューの「プロフィールとして開く」で、リンク先を探している途中。見つかると別の画面に移るため、アプリ全体のもの。
        case profileLookup
        #if DEBUG
        /// `scia-debug://notice/progress`で出す、確かめるための処理中。アプリ全体のもの。
        case debug
        #endif
    }

    private var entries: [(slot: Slot, notice: Notice)] = []

    var isEmpty: Bool { entries.isEmpty }

    /// 持っているアプリ内通知のid。出た順。
    var ids: [String] { entries.map(\.notice.id) }

    func notice(in slot: Slot) -> Notice? {
        entries.first { $0.slot == slot }?.notice
    }

    /// `slot`のアプリ内通知を置き換える。nilなら外す。同じアプリ内通知（同じid）の書き換えなら、出た順の位置を保つ。
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

    /// チップに出す1件の出どころ。なければnil。
    var chosenSlot: Slot? {
        guard let (chosen, _) = PersistentNoticeChoice.choose(entries.map(\.notice), isFailure: { $0.kind == .failure }) else { return nil }
        return entries.first { $0.notice.id == chosen.id }?.slot
    }

    /// チップに出す1件。失敗を優先し、次に処理の途中、その中では新しいものを選ぶ。
    /// 2件以上なら残りの件数を、選んだアプリ内通知が添えていた件数に足して添え、押すと`showAll`で「操作の状況」の一覧を開く。
    /// - Parameter showAll: nilなら一覧を開けないので、選んだアプリ内通知の続きを出す。
    func chipNotice(showAll: (@MainActor () -> Void)?) -> Notice? {
        guard let (chosen, others) = PersistentNoticeChoice.choose(entries.map(\.notice), isFailure: { $0.kind == .failure }) else { return nil }
        var notice = chosen
        notice.additionalCount += others
        if others > 0, let showAll {
            notice.action = .disclosure(hint: "操作の状況を開きます。", handler: showAll)
        }
        return notice
    }
}
