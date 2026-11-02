/// 書いていないときの投稿欄の出し方。設定の画面では、`hidesEmptyComposeBar`と`keepsComposeBarOpen`の2つを、この1つの選択で選ぶ。
public enum ComposeBarIdle: CaseIterable, Sendable {
    /// 空の投稿欄を隠す。下書きや返信先があって出ているときは、折りたたむ。
    case hidden
    /// 細いカプセルに折りたたむ。
    case collapsed
    /// 書いているときの形のまま出しておく。
    case open
}

extension AppSettings {
    /// 隠すうえで、出ているときは折りたたまない組み合わせは選ばせない（docs/compose.md）。読むときは、隠すことを先に見て`hidden`にする。
    public var composeBarIdle: ComposeBarIdle {
        get {
            if hidesEmptyComposeBar { .hidden } else if keepsComposeBarOpen { .open } else { .collapsed }
        }
        set {
            hidesEmptyComposeBar = newValue == .hidden
            keepsComposeBarOpen = newValue == .open
        }
    }
}
