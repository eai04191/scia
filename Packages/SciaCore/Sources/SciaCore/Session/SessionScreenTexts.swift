/// アプリ内のSafariのシートのグラバーの読み上げ。
public enum InAppBrowserSheetTexts {
    public static let grabber = "シートグラバー"

    /// - Parameter isCollapsed: シートを折りたたんでいる。
    public static func grabberValue(isCollapsed: Bool) -> String {
        isCollapsed ? "折りたたまれました" : "広げられました"
    }
}

/// 投稿を読み直したAPIの応答のJSONの画面の文言。題は、開く項目の名前（`StatusMenuItem.apiResponse`）を使う。
public enum APIResponseTexts {
    public static let copy = "コピー"
    public static let loadFailure = "APIの応答を読み込めませんでした"
    public static let retry = "再試行"
}
