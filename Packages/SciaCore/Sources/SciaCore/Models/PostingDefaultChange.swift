import Foundation

/// 新しく投稿するときの既定の、1つの変更。決まりはdocs/account-screen.mdの「投稿のデフォルト」にある。
/// https://docs.joinmastodon.org/methods/accounts/#update_credentials
public enum PostingDefaultChange: Sendable, Equatable {
    /// サーバーが受け付けるのは、公開、ひかえめな公開、フォロワーのみ。
    case visibility(Status.Visibility)
    case sensitive(Bool)
    /// nilなら決めず、サーバーに任せる。
    case language(String?)
    case quotePolicy(QuotePolicy)

    /// 既定の公開範囲に選べるもの。
    public static let visibilityChoices: [Status.Visibility] = [.public, .unlisted, .private]

    var formItem: URLQueryItem {
        switch self {
        case .visibility(let visibility): URLQueryItem(name: "source[privacy]", value: visibility.rawValue)
        case .sensitive(let sensitive): URLQueryItem(name: "source[sensitive]", value: sensitive ? "true" : "false")
        // 空の値で、決めていない状態に戻る。
        case .language(let language): URLQueryItem(name: "source[language]", value: language ?? "")
        case .quotePolicy(let policy): URLQueryItem(name: "source[quote_policy]", value: policy.rawValue)
        }
    }

    /// 変えたあとの既定。保存を待たずに画面へ反映するために使う。
    public func applied(to preferences: ServerPreferences) -> ServerPreferences {
        var preferences = preferences
        switch self {
        case .visibility(let visibility): preferences.defaultVisibility = visibility
        case .sensitive(let sensitive): preferences.defaultSensitive = sensitive
        case .language(let language): preferences.defaultLanguage = language
        case .quotePolicy(let policy): preferences.defaultQuotePolicy = policy
        }
        return preferences
    }
}
