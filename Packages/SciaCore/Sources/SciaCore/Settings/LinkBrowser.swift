public import Foundation

/// 本文のURLのリンクを、どこで開くか。
public enum LinkBrowser: String, CaseIterable, Sendable {
    /// 既定のブラウザ（ふつうはSafari）に切り替えて開く。
    case external
    /// アプリの中に、Safariの画面をシートで重ねて開く。アプリは手前にいたままなので、読んでいる間もストリーミングが流れ続ける。
    case inApp

    /// `url`を実際にどこで開くか。アプリ内のSafariはhttpとhttpsのURLしか開けず、ほかのスキームを渡すと例外で落ちる。
    /// Mastodonは本文のリンクにgeminiやmagnetなども許しているため、それらは設定にかかわらず外で開く。
    /// https://docs.joinmastodon.org/spec/activitypub/#sanitization
    public func browser(for url: URL) -> LinkBrowser {
        guard self == .inApp, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .external }
        return .inApp
    }
}
