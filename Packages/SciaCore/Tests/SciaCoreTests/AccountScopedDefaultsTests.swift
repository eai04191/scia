import Foundation
import Testing
@testable import SciaCore

@MainActor
struct AccountScopedDefaultsTests {
    private func credential(_ username: String, accountID: String, host: String = "example.social") throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://\(host)")),
            accessToken: "token-\(username)",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: accountID,
            username: username
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "AccountScopedDefaultsTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// ログアウトしたら、そのアカウントのために覚えた値（最近のメンション、タブの並び、最後に開いたタブ）を全部消す。
    /// サーバーごとの値（最近使った絵文字、処理できない形式）は、同じサーバーのアカウントが残っている間は残し、いなくなったら消す。
    /// ホスト名にも「.」が入るため、名前が前に一致する別のサーバーのアカウントとサーバーの値を巻き込まない。
    @Test func keepsDataOfServerWhoseNameStartsTheSame() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let alice = try credential("alice", accountID: "1")
        let other = try credential("alice", accountID: "1", host: "example.social.jp")
        let settings = AppSettings(defaults: defaults)
        settings.setSwitchTabItem(.notifications, for: other.handle)
        RecentEmojis(defaults: defaults, instance: other.instance).record("blobcat")

        AccountScopedDefaults.removeData(of: alice, remaining: [other], defaults: defaults, settings: settings)

        #expect(AppSettings(defaults: defaults).switchTabItem(for: other.handle) == .notifications)
        #expect(RecentEmojis(defaults: defaults, instance: other.instance).keys == ["blobcat"])
    }

    @Test func removesAccountDataAndServerDataWithLastAccount() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let alice = try credential("alice", accountID: "1")
        let bob = try credential("bob", accountID: "2")
        let settings = AppSettings(defaults: defaults)
        for account in [alice, bob] {
            RecentMentions(defaults: defaults, account: account.handle).record(LocalMention(mention: Mention(id: "9", username: "carol", url: nil, acct: "carol@remote.example")))
            settings.setTabLayout(MenuLayout(tokens: ["home", "notifications"]), for: account.handle)
            settings.setSwitchTabItem(.notifications, for: account.handle)
        }
        RecentEmojis(defaults: defaults, instance: alice.instance).record("blobcat")
        UnprocessableMediaFormats(defaults: defaults, instance: alice.instance).record("image/heic", serverVersion: "4.7.3", date: Date(timeIntervalSince1970: 1_800_000_000))

        AccountScopedDefaults.removeData(of: alice, remaining: [bob], defaults: defaults, settings: settings)

        let keys = defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []
        #expect(!keys.contains { $0.contains(alice.handle) || $0.contains(alice.id) }, "\(keys)")
        #expect(RecentMentions(defaults: defaults, account: alice.handle).mentions.isEmpty)
        #expect(settings.tabLayout(for: alice.handle) == TabItem.defaultLayout)
        #expect(settings.switchTabItem(for: alice.handle) == nil)
        // 消したアカウントの値は、作り直した設定にも戻らない。
        #expect(AppSettings(defaults: defaults).switchTabItem(for: alice.handle) == nil)
        // 残ったアカウントと、そのサーバーの値は残す。
        #expect(RecentMentions(defaults: defaults, account: bob.handle).mentions.map(\.id) == ["9"])
        #expect(AppSettings(defaults: defaults).switchTabItem(for: bob.handle) == .notifications)
        #expect(RecentEmojis(defaults: defaults, instance: bob.instance).keys == ["blobcat"])

        AccountScopedDefaults.removeData(of: bob, remaining: [], defaults: defaults, settings: settings)

        #expect(defaults.persistentDomain(forName: suite)?.keys.contains { $0.hasPrefix("account.") || $0.hasPrefix("server.") } != true)
        #expect(RecentEmojis(defaults: defaults, instance: bob.instance).keys.isEmpty)
    }
}
