import SciaCore
import SwiftUI
import UIKit

/// 設定の「カスタム絵文字」の画面。アプリの設定は変えず、カタログ用の設定に描き方を変えた絵文字を入れて並べる。
/// 変えた絵文字がないときの行と、長いショートコードとサーバー名、どの描き方も並べる。選び直したりスワイプで削除したりすると、カタログ用の設定が変わる。
enum CustomEmojiDisplaysCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            state("変えた絵文字がない", rules: []),
            state("どの描き方も", rules: CustomEmojiDisplay.allCases.filter { $0 != .plays }.enumerated().map { index, display in
                rule("emoji\(index)", domain: "stellaria.network", display: display, color: .systemOrange)
            }),
            state("長いショートコードとサーバー名", rules: [
                rule("a_very_long_shortcode_for_checking_truncation_of_custom_emoji", domain: "a-very-long-server-name-for-checking-truncation.example.social", display: .shortcode, color: .systemTeal),
                rule("blobcat", domain: "fedibird.com", display: .playsSlowly, color: .systemPink),
            ]),
        ]
    }

    private static func rule(_ shortcode: String, domain: String, display: CustomEmojiDisplay, color: UIColor) -> CustomEmojiDisplayRule {
        let url = CatalogFixtures.imageURL(width: 64, height: 64, color: color, label: String(shortcode.prefix(1))) ?? URL(filePath: "/")
        return CustomEmojiDisplayRule(id: CustomEmojiID(shortcode: shortcode, domain: domain), display: display, url: url, staticUrl: url)
    }

    @MainActor
    private static func state(_ title: String, rules: [CustomEmojiDisplayRule]) -> CatalogState {
        CatalogState(title: title) {
            let suiteName = "net.mizle.scia.catalog.customEmojis.\(title)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("カタログのUserDefaultsを作れない")
            }
            defaults.removePersistentDomain(forName: suiteName)
            let settings = AppSettings(defaults: defaults)
            settings.customEmojiDisplayRules = rules
            let controller = UIHostingController(rootView: NavigationStack {
                CustomEmojiDisplaySettingsView(settings: settings)
            })
            return CatalogControllerHost(controller, height: 860)
        }
    }
}
