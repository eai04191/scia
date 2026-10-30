/// 投稿欄でリンクにタイトルを付けるときの知らせ。カタログでも同じ文言を並べるため、投稿欄の外から作れるようにする。
extension Notice {
    /// タイトルを付けられなかった。押し直せば済むので、数秒で消えるチップで知らせる。読めなかったときは、押すと理由を出す。
    public static func linkTitleFailed(_ failure: LinkTitleFailure, showReason: @escaping @MainActor () -> Void) -> Notice {
        switch failure {
        case .unreadable: Notice(id: "compose.linkTitle", kind: .failure, title: failure.title, action: .disclosure(hint: "理由を見られます。", handler: showReason))
        case .noTitle: Notice(id: "compose.linkTitle", kind: .failure, title: failure.title)
        }
    }
}

/// リンクにタイトルを付けられなかった理由。
public enum LinkTitleFailure {
    /// 通信の失敗や、読み終わる前に時間切れになったとき。
    case unreadable(any Error)
    /// ページを読めたが、タイトルがなかったか空だった。
    case noTitle

    /// チップと「操作の状況」に出す、何ができなかったか。
    public var title: String {
        switch self {
        case .unreadable: "タイトルを読み込めませんでした"
        case .noTitle: "ページにタイトルがありませんでした"
        }
    }
}
