#if DEBUG
import Foundation
import SciaCore
import UIKit

/// サーバーのお知らせのシート。画面ごと置き、通信しない口を渡したモデルで行を入れる。
/// サーバーに出してもらわないと実物で見られない形（期間、リアクションを許さない、読めない）と、長さで崩れうる形を並べる。
enum AnnouncementsCatalog {
    private struct CatalogError: LocalizedError {
        var errorDescription: String? { "カタログの読み込みの失敗" }
    }

    /// 日時の年を省くかが、カタログを開いた年で変わらないよう、今を決めておく。
    private static let now = Date(timeIntervalSince1970: 1_793_500_000)

    private static func date(_ string: String) -> Date {
        (try? Date(string, strategy: .iso8601)) ?? now
    }

    private static let blobcat: CustomEmoji? = CatalogFixtures.imageURL(width: 64, height: 64, color: .systemOrange, label: "猫").map {
        CustomEmoji(shortcode: "blobcat", url: $0, staticUrl: $0)
    }

    private static func announcement(
        _ id: String,
        _ content: String,
        startsAt: String? = nil,
        endsAt: String? = nil,
        allDay: Bool = false,
        publishedAt: String = "2026-10-30T03:00:00Z",
        read: Bool? = false,
        reactions: [AnnouncementReaction] = [],
        reactionsAllowed: Bool = true
    ) -> Announcement {
        Announcement(
            id: id,
            content: content,
            startsAt: startsAt.map(date),
            endsAt: endsAt.map(date),
            allDay: allDay,
            publishedAt: date(publishedAt),
            read: read,
            mentions: [Mention(id: "1", username: "admin", url: URL(string: "https://example.social/@admin"), acct: "admin")],
            tags: [Tag(name: "お知らせ", url: URL(string: "https://example.social/tags/お知らせ"))],
            emojis: blobcat.map { [$0] } ?? [],
            reactions: reactions,
            reactionsAllowed: reactionsAllowed
        )
    }

    private static var customReaction: AnnouncementReaction {
        AnnouncementReaction(name: "blobcat", count: 12, me: false, url: blobcat?.url, staticUrl: blobcat?.staticUrl)
    }

    @MainActor
    static func states() -> [CatalogState] {
        let longBody = "<p>" + String(repeating: "長い本文が何行にもわたるときの折り返しを確かめるための文。", count: 5) + "</p><p>詳しくは<a href=\"https://example.social/about\">サーバーについて</a>を見てください :blobcat:</p>"
        let manyReactions = ["👍", "🎉", "❤️", "😂", "🙏", "👀", "🔥"].enumerated().map { index, name in
            AnnouncementReaction(name: name, count: [1, 23, 456, 7_890, 2, 1, 98_765][index], me: index == 1)
        } + [customReaction]
        return [
            state("未読と既読（期間あり、期間なし）", rows: [
                announcement("3", "<p>11月3日の11時から13時まで、メンテナンスで止まります。</p>", startsAt: "2026-11-03T02:00:00Z", endsAt: "2026-11-03T04:00:00Z"),
                announcement("2", "<p>新しいカスタム絵文字を足しました :blobcat:</p>", read: true, reactions: [AnnouncementReaction(name: "🎉", count: 4, me: true), customReaction]),
            ]),
            state("終日、日をまたぐ、年をまたぐ期間", rows: [
                announcement("6", "<p>終日の期間</p>", startsAt: "2026-11-02T15:00:00Z", endsAt: "2026-11-02T15:00:00Z", allDay: true, read: true),
                announcement("5", "<p>日をまたぐ期間</p>", startsAt: "2026-11-03T14:00:00Z", endsAt: "2026-11-04T02:00:00Z", read: true),
                announcement("4", "<p>年をまたぐ終日の期間</p>", startsAt: "2026-12-30T15:00:00Z", endsAt: "2027-01-02T15:00:00Z", allDay: true, read: true),
            ]),
            state("長い本文（リンク、メンション、ハッシュタグ、カスタム絵文字）", rows: [
                announcement("7", "<p><span class=\"h-card\"><a href=\"https://example.social/@admin\" class=\"u-url mention\">@<span>admin</span></a></span> より <a href=\"https://example.social/tags/お知らせ\" class=\"mention hashtag\" rel=\"tag\">#<span>お知らせ</span></a></p>" + longBody, read: true),
            ]),
            state("折り返すほど多いリアクション（自分がしたもの、カスタム絵文字、大きい数）", rows: [
                announcement("8", "<p>リアクションが多いお知らせ</p>", read: true, reactions: manyReactions),
            ]),
            state("リアクションを許さないお知らせ", rows: [
                announcement("9", "<p>サーバーがリアクションを止めているときのお知らせ</p>", read: true, reactions: [AnnouncementReaction(name: "👍", count: 3, me: false)], reactionsAllowed: false),
            ]),
            state("読めなかったお知らせの行", rows: [
                announcement("10", "<p>読めたお知らせ</p>", read: true),
            ], unreadable: [UnreadableItem(id: "11", url: nil)]),
            state("お知らせがない", rows: []),
            state("読み込みの失敗（行がない）", rows: [], fails: true),
            state("読み込みの失敗（行がある）", rows: [announcement("12", "<p>前に読めたお知らせ</p>", read: true)], fails: true),
        ]
    }

    /// 未読のお知らせは、開いている間に点が消えないよう、既読を送らずに止める。
    /// - Parameter fails: 一覧の読み込みを失敗させる。行は、ストリーミングで届いたものとして入れる。
    @MainActor
    private static func state(_ title: String, rows: [Announcement], unreadable: [UnreadableItem] = [], fails: Bool = false) -> CatalogState {
        CatalogState(title: title) {
            let list = AnnouncementList(announcements: rows, unreadable: unreadable)
            let operations = AnnouncementsModel.Operations(
                list: {
                    if fails { throw CatalogError() }
                    return list
                },
                dismiss: { _ in try await Task.sleep(for: .seconds(3_600)) },
                addReaction: { _, _ in },
                removeReaction: { _, _ in }
            )
            let model = AnnouncementsModel(operations: operations, streamingHub: nil, tasks: TaskScope()) {}
            if fails {
                for row in rows {
                    model.apply(.announcement(row))
                }
            }
            let completion = TextInputCompletion(completion: ComposeCompletion(sources: .unavailable, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning)), recentEmojis: nil)
            let controller = AnnouncementsViewController(model: model, completion: completion, now: { now })
            return CatalogControllerHost(UINavigationController(rootViewController: controller), height: rows.isEmpty ? 260 : 480)
        }
    }
}
#endif
