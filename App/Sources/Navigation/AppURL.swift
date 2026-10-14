import Foundation

/// 他のアプリやショートカットから、`scia://profile/user@example.social`のようなURLでSciaの画面を開く。
enum AppURL: Equatable {
    static let scheme = "scia"

    /// `scia://profile/<user@domain>`。ローカルのアカウントは`<user>`だけでもよい。ホームのタブにプロフィールを開く。
    case profile(acct: String)

    init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host() {
        case "profile":
            // `@user@domain`の形で書かれていても読めるよう、先頭の@を外す。
            let acct = url.lastPathComponent.hasPrefix("@") ? String(url.lastPathComponent.dropFirst()) : url.lastPathComponent
            guard !acct.isEmpty, acct != "/" else { return nil }
            self = .profile(acct: acct)
        default:
            return nil
        }
    }
}
