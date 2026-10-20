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
