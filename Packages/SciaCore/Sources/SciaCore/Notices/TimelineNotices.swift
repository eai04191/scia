/// タイムラインで出す知らせの中身。カタログでも同じ文言を並べるため、タイムラインの外に置く。
extension Notice {
    /// 投稿への操作（お気に入り、ブースト）の失敗。数秒で消え、押すと理由が出る。
    /// - Parameter title: 何が失敗したか。「お気に入りを変更できませんでした」など。
    public static func interactionFailure(title: String, showReason: @escaping @MainActor () -> Void) -> Notice {
        Notice(id: "timeline.interactionFailure", kind: .failure, title: title, action: .disclosure(hint: "理由を見られます。", handler: showReason))
    }

    /// リンクのメニューの「プロフィールとして開く」で、リンク先を探している途中。サーバーが相手のページを取りに行くため、時間がかかることがある。
    public static let profileLookup = Notice(id: "timeline.profileLookup", kind: .progress, title: "取得中")

    /// まとめてブーストの途中。済んだ件数と全体の件数を出し、押すと止めるかの確認を出す。決まりはdocs/batch-actions.mdの「ブースト」にある。
    public static func batchReblog(completed: Int, total: Int, onStop: @escaping @MainActor () -> Void) -> Notice {
        Notice(id: "timeline.batchReblog", kind: .progress, title: "ブースト中", value: "\(completed)/\(total)", action: .disclosure(hint: "まとめてブーストを中止するか選べます。", handler: onStop), valueIsProgress: true)
    }

    /// まとめてブーストが`index`番目（0から数える）の投稿で失敗して止まったときの文言。
    public static func batchReblogFailureTitle(index: Int) -> String {
        "\(index + 1)件目をブーストできませんでした"
    }

    /// まとめて共有するメディアを落としている途中。落とし終えた数と全体の数を出し、押すと止めるかの確認を出す。決まりはdocs/batch-actions.mdの「共有」にある。
    public static func batchDownload(completed: Int, total: Int, onStop: @escaping @MainActor () -> Void) -> Notice {
        Notice(id: "timeline.batchDownload", kind: .progress, title: "ダウンロード中", value: "\(completed)/\(total)", action: .disclosure(hint: "ダウンロードを中止するか選べます。", handler: onStop), valueIsProgress: true)
    }

    /// まとめて共有するメディアを落とせなかった。
    public static let batchShareFailureTitle = "共有するメディアをダウンロードできませんでした"

    /// 投稿のリンクをコピーした。コピーは画面の変化で見えないため知らせる。
    public static let linkCopied = Notice(id: "timeline.linkCopied", kind: .success, title: "リンクをコピーしました")

    /// ユーザーのメニューで、ハンドルかその一部をコピーした。
    public static func handleCopied(_ part: UserHandlePart) -> Notice {
        switch part {
        case .handle: Notice(id: "timeline.handleCopied", kind: .success, title: "ハンドルをコピーしました")
        case .username: Notice(id: "timeline.usernameCopied", kind: .success, title: "ユーザー名をコピーしました")
        case .server: Notice(id: "timeline.serverCopied", kind: .success, title: "サーバーをコピーしました")
        }
    }

    /// 投稿の本文をコピーした。
    public static let textCopied = Notice(id: "timeline.textCopied", kind: .success, title: "テキストをコピーしました")

    /// タップや長押しに選んだメニューの項目が、押した対象では使えない（他人の投稿の「編集」など）。決まりはdocs/object-actions.mdの「項目を行う」にある。
    /// 押した直後で何に対してかは分かるため、対象の呼び名（「この投稿では」）は付けない。付けると項目の名前が長いときに2行に折り返すため、付けずに1行に収める。
    /// - Parameter reason: 項目が押せない理由（項目のサブタイトル）。あれば、それを文言にする。
    public static func objectActionUnavailable(itemTitle: String, reason: String?) -> Notice {
        Notice(id: "objectAction.unavailable", kind: .info, title: reason ?? "“\(itemTitle)”を使えません")
    }
}
