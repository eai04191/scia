#if DEBUG
import Foundation
import SciaCore
import UIKit

/// READMEのスクリーンショットのシナリオ。撮る場面はdocs/promo-video.mdの「READMEのスクリーンショット」にある。起動の引数`-scenario readme`で選ぶ。
/// 投稿、通知、新着は「流れても、動かない」（`StreamingDemoScenario`）のものを使い、タブの並び、リスト、写真付きの下書き、ハッシュタグの補完を足す。
enum ReadmeScreenshotsScenario {
    /// 切り替えタブに入れるリスト。中身は、ホームの投稿のうち3人のもの。
    private static let list = MastodonList(id: "1", title: "モリーオ")
    private static let listMemberIDs: Set<String> = ["101", "103", "105"]

    /// 下書きの本文。2枚目では、末尾に`#`を足してハッシュタグの補完を出す。
    private static let draftText = ScenarioDummyText.sentence(from: 1, count: 2)

    static func make(launchedAt now: Date) -> ScenarioScript {
        let base = StreamingDemoScenario.make(launchedAt: now)
        var script = ScenarioScript(
            credential: base.credential,
            responses: base.responses.merging(responses(base: base)) { _, new in new },
            lists: base.lists.merging(["api/v1/timelines/list/\(list.id)": listTimeline(base: base)]) { _, new in new },
            events: base.events,
            interval: base.interval
        )
        script.postResponses = ["api/v2/media": uploadedMedia]
        script.actions = [
            "draft": .compose(text: draftText, mediaCount: 3),
            "draft-close": .composeClose,
            "draft-hashtag": .compose(text: draftText + "#", mediaCount: 0),
        ]
        script.draftImages = { draftImages() }
        let handle = base.credential.handle
        let list = list
        script.configure = { settings, _ in
            // ホーム、ローカル、通知を並べ、連合とリストを右端の切り替えタブに入れる。切り替えタブはリストを開いておく。
            settings.setTabLayout(MenuLayout(elements: [
                .item(.home, isVisible: true),
                .item(.local, isVisible: true),
                .item(.notifications, isVisible: true),
                .more,
                .item(.list(id: list.id, title: list.title), isVisible: true),
                .item(.federated, isVisible: true),
                .item(.bookmarks, isVisible: false),
                .item(.favourites, isVisible: false),
            ]), for: handle)
            settings.setSwitchTabItem(.list(id: list.id, title: list.title), for: handle)
        }
        return script
    }

    private static func responses(base: ScenarioScript) -> [String: Data] {
        // 通知のタブにバッジを出すため、既読の位置を一番新しい通知より前に置く。
        guard let notifications = base.lists["api/v1/notifications"], notifications.count >= 3, let home = base.lists["api/v1/timelines/home"]?.first else {
            preconditionFailure("元のシナリオに通知かホームがない")
        }
        let markers: [String: Any] = [
            "home": ["last_read_id": home.id, "version": 1, "updated_at": "2026-01-01T00:00:00.000Z"],
            "notifications": ["last_read_id": notifications[2].id, "version": 1, "updated_at": "2026-01-01T00:00:00.000Z"],
        ]
        let domain = ScenarioFixtures.domain
        let featured: [[String: Any]] = [
            ["id": "1", "name": "イーハトーヴォ", "url": "https://\(domain)/@kyuste/tagged/イーハトーヴォ", "statuses_count": 128, "last_status_at": "2026-01-01"],
            ["id": "2", "name": "モリーオ", "url": "https://\(domain)/@kyuste/tagged/モリーオ", "statuses_count": 64, "last_status_at": "2026-01-01"],
        ]
        let suggestions: [[String: Any]] = ["ポラーノ", "幻燈"].map { name in
            ["name": name, "url": "https://\(domain)/tags/\(name)", "history": [Any]()]
        }
        return [
            "api/v1/markers": ScenarioFixtures.json(markers),
            "api/v1/lists": ScenarioFixtures.json([["id": list.id, "title": list.title, "replies_policy": "list", "exclusive": false]]),
            "api/v1/followed_tags": ScenarioFixtures.json([Any]()),
            "api/v1/featured_tags": ScenarioFixtures.json(featured),
            "api/v1/featured_tags/suggestions": ScenarioFixtures.json(suggestions),
        ]
    }

    /// ホームの投稿のうち、リストに入れた人のもの。
    private static func listTimeline(base: ScenarioScript) -> [ScenarioScript.Item] {
        (base.lists["api/v1/timelines/home"] ?? []).filter { item in
            let object = try? JSONSerialization.jsonObject(with: item.json) as? [String: Any]
            let account = object?["account"] as? [String: Any]
            return (account?["id"] as? String).map(listMemberIDs.contains) ?? false
        }
    }

    /// 送った添付ファイルを、変換を終えたものとして返す。投稿欄はサムネイルを手元の画像で描くので、`url`は読まれない。
    @Sendable private static func uploadedMedia(sequence: Int) -> Data {
        let size: [String: Any] = ["width": 1_600, "height": 1_200, "aspect": 4.0 / 3.0]
        let url = "https://\(ScenarioFixtures.domain)/media/\(sequence).jpg"
        return ScenarioFixtures.json([
            "id": "9000\(sequence)",
            "type": "image",
            "url": url,
            "preview_url": url,
            "remote_url": NSNull(),
            "description": NSNull(),
            "blurhash": NSNull(),
            "meta": ["original": size, "small": size],
        ] as [String: Any])
    }

    /// 下書きに添付する写真。タイムラインの写真と別の模様にする。
    @MainActor private static func draftImages() -> [UIImage] {
        ["draft-1", "draft-2", "draft-3"].map { ScenarioArtwork.photoImage($0, size: CGSize(width: 1_200, height: 900)) }
    }
}
#endif
