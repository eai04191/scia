public import Foundation

/// アカウントごと、サーバーごとに覚える値のキー。キーの頭を`account.<ハンドル>/`と`server.<ホスト>/`に揃え、ログアウトでその頭のキーをまとめて消す。
/// ハンドルとホストの後ろは、どちらにも出ない「/」で区切る。「.」で区切ると、`example.social`の頭が`example.social.jp`のキーにも一致するため。
/// 覚える値を足すときは、ここでキーを作る。ほかの形のキーにすると、ログアウトしても残る。
public enum AccountScopedDefaults {
    /// アカウントのための値のキー。
    public static func key(_ name: String, account handle: String) -> String {
        "\(accountPrefix(handle))\(name)"
    }

    /// サーバーのための値のキー。同じサーバーのアカウントが残っている間は残す。
    public static func key(_ name: String, server instance: URL) -> String {
        "\(serverPrefix(instance))\(name)"
    }

    /// `name`の値を覚えているアカウントのハンドルと、その値。
    public static func accountValues(named name: String, in defaults: UserDefaults) -> [String: Any] {
        let suffix = "/\(name)"
        var values: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(accountKeyPrefix) && key.hasSuffix(suffix) {
            values[String(key.dropFirst(accountKeyPrefix.count).dropLast(suffix.count))] = value
        }
        return values
    }

    /// ログアウトしたアカウントのために覚えた値を消す。同じサーバーのアカウントが`remaining`にいなければ、サーバーのための値も消す。
    @MainActor
    public static func removeData(of credential: Credential, remaining: [Credential], defaults: UserDefaults, settings: AppSettings) {
        var prefixes = [accountPrefix(credential.handle)]
        if !remaining.contains(where: { serverPrefix($0.instance) == serverPrefix(credential.instance) }) {
            prefixes.append(serverPrefix(credential.instance))
        }
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
        settings.forgetAccount(credential.handle)
    }

    private static let accountKeyPrefix = "account."

    private static func accountPrefix(_ handle: String) -> String {
        "\(accountKeyPrefix)\(handle)/"
    }

    private static func serverPrefix(_ instance: URL) -> String {
        "server.\(instance.host() ?? instance.absoluteString)/"
    }
}
