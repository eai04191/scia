public import Foundation

/// 本文のURLのリンクを、どこで開くか。
public enum LinkBrowser: String, CaseIterable, Sendable {
    /// 既定のブラウザ（ふつうはSafari）に切り替えて開く。
    case external
    /// アプリの中に、Safariの画面をシートで重ねて開く。アプリは手前にいたままなので、読んでいる間もストリーミングが流れ続ける。
    case inApp
    /// アプリの中に、Safariの画面を全画面で重ねて開く。右から入り、左端から右へのスワイプで閉じる。
    case inAppFullScreen

    /// `url`を実際にどこで開くか。アプリ内のSafariはhttpとhttpsのURLしか開けず、ほかのスキームを渡すと例外で落ちる。
    /// Mastodonは本文のリンクにgeminiやmagnetなども許しているため、それらは設定にかかわらず外で開く。
    /// https://docs.joinmastodon.org/spec/activitypub/#sanitization
    public func browser(for url: URL) -> LinkBrowser {
        guard opensInApp, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .external }
        return self
    }

    /// アプリの中で開くか。
    public var opensInApp: Bool { self != .external }
}

extension LinkBrowser {
    /// 設定の選択肢の名前。
    public var title: String {
        switch self {
        case .external: "デフォルトのブラウザ"
        case .inApp: "アプリ内のSafari（シート）"
        case .inAppFullScreen: "アプリ内のSafari（全画面）"
        }
    }
}
