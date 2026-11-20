import SciaCore
import SwiftUI
import UIKit

enum UserDisplaysCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [state(fails: false), state(fails: true)]
    }

    @MainActor
    private static func state(fails: Bool) -> CatalogState {
        CatalogState(title: fails ? "アイコンを取得できない" : "長い表示名とハンドル・アニメーション停止のみ") {
            let suite = "net.mizle.scia.catalog.userDisplayList.\(fails)"
            guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("カタログのUserDefaultsを作れない") }
            defaults.removePersistentDomain(forName: suite)
            let settings = AppSettings(defaults: defaults)
            let long = CatalogFixtures.account(acct: "a_very_long_username@a-very-long-server-name-for-checking-truncation.example.social")
            let emoji = CatalogFixtures.imageURL(width: 24, height: 24, color: .systemPink).map { CustomEmoji(shortcode: "square", url: $0, staticUrl: $0) }
            let animation = Account(id: "alice", username: "alice", acct: "alice@example.social", displayName: "カタログ :square:", avatar: long.avatar, emojis: emoji.map { [$0] } ?? [])
            do {
                try settings.userDisplays.save(.init(name: "仕事の連絡をするために覚えているとても長い表示名", stopsAnimation: true), for: long, in: settings)
                try settings.userDisplays.save(.init(stopsAnimation: true), for: animation, in: settings)
            } catch { preconditionFailure("カタログの設定を保存できない") }
            let avatars = UserDisplayLoader(settings: settings, tasks: TaskScope()) { handle in
                if fails { throw URLError(.notConnectedToInternet) }
                return handle == long.acct ? long : animation
            }
            let controller = UIHostingController(rootView: NavigationStack {
                UserDisplaySettingsView(settings: settings, open: { _ in }, loader: avatars)
            })
            return CatalogControllerHost(controller, height: 560)
        }
    }
}
