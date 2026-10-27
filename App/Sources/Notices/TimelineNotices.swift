import Foundation

/// タイムラインで出す知らせの中身。カタログでも同じ文言を並べるため、タイムラインの外に置く。
extension Notice {
    /// 投稿への操作（お気に入り、ブースト）の失敗。数秒で消え、押すと理由が出る。
    /// - Parameter title: 何が失敗したか。「お気に入りを変更できませんでした」など。
    static func interactionFailure(title: String, showReason: @escaping @MainActor () -> Void) -> Notice {
        Notice(id: "timeline.interactionFailure", kind: .failure, title: title, action: .disclosure(hint: "理由を見られます。", handler: showReason))
    }

    /// リンクのメニューの「プロフィールとして開く」で、リンク先を探している途中。サーバーが相手のページを取りに行くため、時間がかかることがある。
    static let profileLookup = Notice(id: "timeline.profileLookup", kind: .progress, title: "取得中")

    /// 投稿のリンクをコピーした。コピーは画面の変化で見えないため知らせる。
    static let linkCopied = Notice(id: "timeline.linkCopied", kind: .success, title: "リンクをコピーしました")

    /// ユーザーのメニューで、サーバー名を付けたハンドルをコピーした。
    static let handleCopied = Notice(id: "timeline.handleCopied", kind: .success, title: "ハンドルをコピーしました")

    /// 投稿の本文をコピーした。
    static let textCopied = Notice(id: "timeline.textCopied", kind: .success, title: "テキストをコピーしました")

    /// タップや長押しに選んだメニューの項目が、押した対象では使えない（他人の投稿の「編集」など）。決まりはdocs/object-actions.mdの「項目を行う」にある。
    /// 押した直後で何に対してかは分かるため、対象の呼び名（「この投稿では」）は付けない。チップは1行で、付けると項目の名前が長いときに「使えません」が切れる。
    /// - Parameter reason: 項目が押せない理由（項目のサブタイトル）。あれば、それを文言にする。
    static func objectActionUnavailable(itemTitle: String, reason: String?) -> Notice {
        Notice(id: "objectAction.unavailable", kind: .info, title: reason ?? "「\(itemTitle)」を使えません")
    }
}
