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
        let mentioned = status(content: "<p>@me 通知の元になった投稿。</p>")
        func row(_ title: String, _ type: MastodonNotification.Kind, status: Status? = mentioned) -> CatalogState {
            CatalogState(title: title) {
                let notification = MastodonNotification(id: UUID().uuidString, type: type, createdAt: .now.addingTimeInterval(-300), account: booster, status: status)
                @MainActor func configuration() -> StatusContentConfiguration {
                    let list = notifications.contentConfiguration(for: notification, base: .cell())
                    return notifications.statusContentConfiguration(list: list, notification: notification)
                }
                let view = configuration().makeContentView()
                // 名前の前のアイコンは、届くまで灰色の枠で出す。一覧と同じく、届いたら組み立て直す。
                AppDependencies.avatarImages.addListener(owner: view) { [weak view] _ in
                    view?.configuration = configuration()
                }
                return CatalogFrame.bordered(view)
            }
        }
        return [
            row("メンション", .mention),
            row("メンション（画像つき）", .mention, status: status(content: "<p>@me 画像つきのメンション。</p>", media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
            ])),
            row("投稿の通知", .status),
            row("ブースト", .reblog),
            row("お気に入り", .favourite),
            row("フォロー", .follow, status: nil),
            row("フォローリクエスト", .followRequest, status: nil),
            row("投票の終了", .poll),
            row("ブーストした投稿の編集", .update),
            row("引用", .quote),
            row("引用した投稿の編集", .quotedUpdate),
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
