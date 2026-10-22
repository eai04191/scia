#if DEBUG
import SciaCore
import UIKit

/// 投稿欄のカスタム絵文字のパレット（`EmojiPaletteView`）の状態。
/// 押しても何も起きない。シートに載せたときの見え方、引き上げたときや検索欄にキーボードを出したときの並び、投稿欄のバーとの重なりは、実物で確かめる。
/// 背景はシートが描くので、ここでは白い地に置く。
enum EmojiPaletteCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        let colors: [UIColor] = [.systemPink, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal]
        let emojis = (0 ..< 40).map { index in
            let url = CatalogFixtures.imageURL(width: 64, height: 64, color: colors[index % colors.count], label: "\(index)") ?? URL(filePath: "/")
            let category: String? = switch index {
            case 0 ..< 14: nil
            case 14 ..< 24: "動物"
            default: "とても長いカテゴリーの名前で、見出しに収まらないときに末尾が切れることを確かめる"
            }
            return ServerEmoji(shortcode: "emoji_\(index)", url: url, staticUrl: url, category: category)
        }
        let standard = StandardEmojiCatalog.groups
        let sections = EmojiPalette.sections(emojis: emojis, standardGroups: standard, recentKeys: ["emoji_3", "🐈", "emoji_20", "👍", "emoji_30"], recentLimit: 24)
        let failure = ComposeCompletion.failureMessage(for: MastodonAPIError(statusCode: 502, message: "Bad Gateway"))
        // カスタム絵文字の一覧がまだないときは、最近使ったもののうちUnicodeの絵文字だけが並ぶ。
        let withoutCustom = EmojiPalette.sections(emojis: [], standardGroups: standard, recentKeys: ["emoji_3", "🐈", "emoji_20", "👍"], recentLimit: 24)
        return [
            CatalogState(title: "最近使ったもの（カスタム絵文字とUnicodeの絵文字）、カテゴリーのないもの、長い名前のカテゴリー") { palette(.sections(sections, customStatus: nil)) },
            CatalogState(title: "最近使ったものがない") { palette(.sections(EmojiPalette.sections(emojis: emojis, standardGroups: standard, recentKeys: [], recentLimit: 24), customStatus: nil)) },
            CatalogState(title: "サーバーにカスタム絵文字がなく、Unicodeの絵文字だけ") { palette(.sections(EmojiPalette.sections(emojis: [], standardGroups: standard, recentKeys: [], recentLimit: 24), customStatus: nil)) },
            CatalogState(title: "カスタム絵文字の一覧を読んでいる（Unicodeの絵文字は並ぶ）") { palette(.sections(withoutCustom, customStatus: .loading)) },
            CatalogState(title: "カスタム絵文字の一覧を読めなかった（押すと読み込み直す）") { palette(.sections(withoutCustom, customStatus: .failed(failure))) },
            CatalogState(title: "並べる絵文字がない") { palette(.sections([], customStatus: nil)) },
            CatalogState(title: "検索の結果（カスタム絵文字）") { palette(.searchResults(Array(emojis.prefix(12)).map(PaletteEmoji.custom), customStatus: nil), query: "emoji") },
            CatalogState(title: "検索の結果（日本語で探したUnicodeの絵文字）") {
                palette(.searchResults(EmojiPalette.searchResults(matching: "ねこ", emojis: emojis, standardGroups: standard, limit: 200), customStatus: nil), query: "ねこ")
            },
            CatalogState(title: "カスタム絵文字の一覧を読めないまま探した") {
                palette(.searchResults(EmojiPalette.searchResults(matching: "ねこ", emojis: [], standardGroups: standard, limit: 200), customStatus: .failed(failure)), query: "ねこ")
            },
            CatalogState(title: "検索で見つからない") { palette(.searchResults([], customStatus: nil), query: "nothing") },
        ]
    }

    @MainActor
    private static func palette(_ content: EmojiPaletteView.Content, query: String = "") -> UIView {
        let palette = EmojiPaletteView(emojiImages: AppDependencies.emojiImages)
        palette.searchField.text = query
        palette.backgroundColor = .systemBackground
        palette.setContent(content)
        return CatalogBackdrop.image(palette) { backdrop, palette in
            [
                palette.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 24),
                palette.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
                palette.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                palette.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                // メディアを選ぶシートの決めた高さ（336pt）から、画面の下の安全領域の分を引いた高さ。
                palette.heightAnchor.constraint(equalToConstant: 302),
            ]
        }
    }
}
#endif
