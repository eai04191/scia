#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 一覧の投稿と通知の行。一覧と同じく`TimelineViewController`の組み立てを通すので、名前の並べ方やアイコンの形、時刻の表記はアプリの設定に従う。
enum PostRowCatalog {
    private typealias Fixtures = CatalogFixtures

    private static let author = Fixtures.account(displayName: "カタログのアカウント", acct: "catalog@example.com")
    private static let booster = Fixtures.account(
        displayName: "ブーストした人",
        acct: "booster@example.com",
        avatar: Fixtures.imageURL(width: 200, height: 200, color: .systemPink)
    )

    @MainActor
    static func postStates() -> [CatalogState] {
        let home = TimelineViewController(texts: .home)
        func post(_ title: String, _ status: Status, isPinned: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                CatalogFrame.bordered(PostContentView(configuration: home.contentConfiguration(for: status, isPinned: isPinned, base: .cell())))
            }
        }
        return [
            post("短い本文", status(content: "<p>短い本文。</p>")),
            post("本文が短く、アイコンの方が下まで届く", status(content: "<p>あ</p>")),
            post("長い本文", status(content: "<p>" + String(repeating: "長い本文が何行にもわたるときの折り返しと、行の高さを確かめるための文。", count: 5) + "</p>")),
            post("ブーストされた投稿", status(content: "<p>ブーストされた投稿。</p>", rebloggedBy: booster)),
            post("固定された投稿", status(content: "<p>プロフィールの上に固定された投稿。</p>"), isPinned: true),
            post("注意書き", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ")),
            post("画像2枚", status(content: "<p>画像を2枚添付した投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
                Fixtures.attachment("b", width: 1_200, height: 900, color: .systemGreen, description: "緑の地に白い格子"),
            ])),
            post("閲覧注意の画像", status(content: "<p>閲覧注意の画像を添付した投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true)),
            post("名前が長い（末尾をぼかす）", status(
                content: "<p>名前が1行に収まらない投稿。</p>",
                account: Fixtures.account(displayName: String(repeating: "とても長い名前", count: 4), acct: "a-very-long-account-name@subdomain.example.com")
            )),
            post("アイコンがない", status(content: "<p>アイコンのURLがないアカウントの投稿。</p>", account: Fixtures.account(acct: "noavatar@example.com", avatar: nil))),
        ]
    }

    @MainActor
    static func notificationStates() -> [CatalogState] {
        let notifications = TimelineViewController(texts: .notifications)
        // メンションなどの投稿は通知を送った人が書き、お気に入りなどで再掲する投稿は自分が書いたもの。
        let mentioned = status(content: "<p>@me 通知の元になった投稿。</p>", account: booster)
        let mine = status(content: "<p>お気に入りやブーストをされた自分の投稿。</p>")
        func row(_ title: String, _ type: MastodonNotification.Kind, status: Status? = mentioned, account: Account = booster) -> CatalogState {
            CatalogState(title: title) {
                let notification = MastodonNotification(id: UUID().uuidString, type: type, createdAt: .now.addingTimeInterval(-300), account: account, status: status)
                @MainActor func configuration() -> any UIContentConfiguration {
                    notifications.contentConfiguration(for: notification, base: .cell())
                }
                let view = configuration().makeContentView()
                // 名前の前のアイコンは、届くまで灰色の枠で出す。一覧と同じく、届いたら組み立て直す。
                AppDependencies.avatarImages.addListener(owner: view) { [weak view] _ in
                    view?.configuration = configuration()
                }
                return CatalogFrame.bordered(view)
            }
        }
        let longBody = "<p>" + String(repeating: "お気に入りに登録された自分の投稿が長いときに、再掲する本文を何行で切るかを確かめるための文。", count: 4) + "</p>"
        return [
            row("メンション", .mention),
            row("メンション（画像つき）", .mention, status: status(content: "<p>@me 画像つきのメンション。</p>", account: booster, media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
            ])),
            row("メンション（投稿が届かなかった）", .mention, status: nil),
            row("投稿の通知", .status),
            row("引用", .quote),
            row("ブースト", .reblog, status: mine),
            row("お気に入り", .favourite, status: mine),
            row("お気に入り（長い本文を切る）", .favourite, status: status(content: longBody)),
            row("お気に入り（注意書き）", .favourite, status: status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ")),
            row("お気に入り（画像2枚、ALTつき）", .favourite, status: status(content: "<p>画像を2枚添付した自分の投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
                Fixtures.attachment("b", width: 900, height: 1_600, color: .systemGreen, description: "緑の地に白い格子"),
            ])),
            row("お気に入り（画像が行に収まらず、横にスクロールする）", .favourite, status: status(content: "<p>画像を6枚添付した自分の投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
                Fixtures.attachment("b", width: 1_200, height: 900, color: .systemGreen),
                Fixtures.attachment("c", width: 1_200, height: 900, color: .systemOrange),
                Fixtures.attachment("d", width: 1_200, height: 900, color: .systemPurple),
                Fixtures.attachment("e", width: 1_200, height: 900, color: .systemRed),
                Fixtures.attachment("f", width: 1_200, height: 900, color: .systemTeal),
            ])),
            row("ブースト（閲覧注意の画像）", .reblog, status: status(content: "<p>閲覧注意の画像を添付した自分の投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true)),
            row("ブースト（本文のない画像だけの投稿）", .reblog, status: status(content: "", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemIndigo),
            ])),
            row("投票の終了", .poll, status: mine),
            row("ブーストした投稿の編集", .update, status: mine),
            row("引用した投稿の編集", .quotedUpdate, status: mine),
            row("フォロー", .follow, status: nil),
            row("フォロー（名前が長い）", .follow, status: nil, account: Fixtures.account(
                displayName: String(repeating: "とても長い名前", count: 4),
                acct: "a-very-long-account-name@subdomain.example.com"
            )),
            row("フォローリクエスト", .followRequest, status: nil),
            row("知らない種類", .other("admin.sign_up"), status: nil),
        ]
    }

    private static func status(
        content: String,
        account: Account = author,
        spoilerText: String = "",
        media: [MediaAttachment] = [],
        sensitive: Bool = false,
        rebloggedBy: Account? = nil
    ) -> Status {
        let original = Status(
            id: UUID().uuidString,
            createdAt: .now.addingTimeInterval(-3_600),
            account: account,
            content: content,
            spoilerText: spoilerText,
            url: nil,
            mediaAttachments: media,
            sensitive: sensitive
        )
        guard let rebloggedBy else { return original }
        return Status(id: UUID().uuidString, createdAt: .now.addingTimeInterval(-600), account: rebloggedBy, content: "", spoilerText: "", url: nil, reblog: original)
    }
}
#endif
