// Config/app-info.jsonからTools/generate-app-info.pyで書き出す。直接編集しない。
import Foundation

enum AppInfo {
    static let privacyPolicy = URL(string: "https://github.com/eai04191/scia/blob/main/PRIVACY.md")
    static let repository = URL(string: "https://github.com/eai04191/scia")
    static let testFlight = URL(string: "https://testflight.apple.com/join/6g69MEf8")

    static let acknowledgmentSections: [AcknowledgmentSection] = [
        AcknowledgmentSection(header: "Sciaは次のクライアントから多くの影響を受けています", items: [
            AcknowledgmentItem(name: "SubwayTooter", github: URL(string: "https://github.com/tateisu/SubwayTooter"), account: "SubwayTooter@mastodon.juggler.jp"),
            AcknowledgmentItem(name: "Metatext", site: URL(string: "https://metabolist.org/"), github: URL(string: "https://github.com/metabolist/metatext")),
            AcknowledgmentItem(name: "iMast", site: URL(string: "https://cinderella-project.github.io/iMast/"), github: URL(string: "https://github.com/cinderella-project/iMast"), account: "imast_ios@mstdn.rinsuki.net"),
            AcknowledgmentItem(name: "DAWN", site: URL(string: "https://noppe.dev/dawn/")),
            AcknowledgmentItem(name: "Mona", account: "MonaApp@mastodon.social"),
            AcknowledgmentItem(name: "twitcle plus"),
            AcknowledgmentItem(name: "Hel1um"),
        ]),
        AcknowledgmentSection(header: "Sciaのコードはすべて次のエージェントが書いています", items: [
            AcknowledgmentItem(name: "Claude Code", site: URL(string: "https://claude.com/product/claude-code")),
            AcknowledgmentItem(name: "Codex", site: URL(string: "https://openai.com/codex/")),
        ]),
    ]

    static let licenses: [LicenseItem] = [
        LicenseItem(
            name: "Twemoji",
            license: "CC BY 4.0",
            copyright: "Copyright Twitter, Inc and other contributors",
            usage: "設定で「Twemoji」を選んだときの絵文字の絵。SVGをカラーフォント（TrueType、COLR形式）に変換して使っています。",
            source: URL(string: "https://github.com/jdecked/twemoji"),
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")
        ),
        LicenseItem(
            name: "Unicode Emoji",
            license: "Unicode License v3",
            copyright: "Copyright © 1991-2026 Unicode, Inc.",
            usage: "投稿欄の絵文字のシートに並べるUnicodeの絵文字のリストとまとまり（emoji-test.txt）。",
            source: URL(string: "https://www.unicode.org/emoji/"),
            licenseURL: URL(string: "https://www.unicode.org/license.txt")
        ),
        LicenseItem(
            name: "Unicode CLDR",
            license: "Unicode License v3",
            copyright: "Copyright © 2015-2024 Unicode, Inc.",
            usage: "投稿欄の絵文字の検索に使う日本語と英語の名前と言葉（CLDRの絵文字の注釈）。",
            source: URL(string: "https://github.com/unicode-org/cldr-json"),
            licenseURL: URL(string: "https://github.com/unicode-org/cldr-json/blob/48.2.3/LICENSE")
        ),
        LicenseItem(
            name: "gemoji",
            license: "MIT",
            copyright: "Copyright (c) 2019 GitHub, Inc.",
            usage: "投稿欄の補完でUnicodeの絵文字を「:+1」や「:thumbsup」のように打って探すための短縮名。",
            source: URL(string: "https://github.com/github/gemoji"),
            licenseURL: URL(string: "https://github.com/github/gemoji/blob/master/LICENSE")
        ),
        LicenseItem(
            name: "FediDB",
            license: "CC BY 4.0",
            copyright: "FediDB",
            usage: "ログイン画面で出すサーバーの候補。FediDBのサーバーのデータセットからMastodonとその派生のサーバーを選び、月間のアクティブユーザーが多い順に並べて使っています。",
            source: URL(string: "https://fedidb.com/datasets"),
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")
        ),
    ]
}
