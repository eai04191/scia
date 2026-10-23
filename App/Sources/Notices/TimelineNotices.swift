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
}
