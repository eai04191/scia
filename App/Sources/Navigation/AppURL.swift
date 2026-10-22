import Foundation

/// 他のアプリやショートカットから、`scia://profile/user@example.social`のようなURLでSciaの画面を開く。
enum AppURL: Equatable {
    /// いつものビルドは`scia`、撮影用のビルドは`scia-promo`。project.ymlの`SCIA_URL_SCHEME`を、Info.plistを通して読む。
    static let scheme: String = {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "SciaURLScheme") as? String else {
            preconditionFailure("Info.plistにSciaURLSchemeがない")
        }
        return scheme
    }()

    /// `scia://profile/<user@domain>`。ローカルのアカウントは`<user>`だけでもよい。ホームのタブにプロフィールを開く。
    case profile(acct: String)
    /// `scia://share?id=<UUID>&unreadable=<件数>`。共有拡張が受け取ったメディア（`SharedMediaInbox`の`id`の共有）を、投稿欄に添付する。
    /// `unreadable`は、拡張が受け取れなかった件数。なければ0。
    case share(id: UUID, unreadableCount: Int)

    init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host() {
        case "profile":
            // `@user@domain`の形で書かれていても読めるよう、先頭の@を外す。
            let acct = url.lastPathComponent.hasPrefix("@") ? String(url.lastPathComponent.dropFirst()) : url.lastPathComponent
            guard !acct.isEmpty, acct != "/" else { return nil }
            self = .profile(acct: acct)
        case "share":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let id = items.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:)) else { return nil }
            let unreadable = items.first { $0.name == "unreadable" }?.value
            guard let unreadableCount = unreadable.map(Int.init) ?? 0, unreadableCount >= 0 else { return nil }
            self = .share(id: id, unreadableCount: unreadableCount)
        default:
            return nil
        }
    }
}
