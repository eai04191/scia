#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 検証のシナリオ「ギャップを読み進める」。既読位置の上にギャップがある起動と、上へ読み進めたときのギャップの読み込みを再現する。
/// 起動の引数`-scenario gap-reading`で選ぶ。使い方はdocs/debug-urls.mdにある。
enum GapReadingScenario {
    /// 既読位置にする投稿の、新しい方から数えた番号。起動すると、最新のページと既読位置の上のページの間にギャップができる。
    private static let markerIndex = 250

    static func make(launchedAt _: Date) -> ScenarioScript {
        let home = posts()
        guard home.count > markerIndex else { preconditionFailure("gap-reading.jsonの投稿が\(markerIndex + 1)件より少ない") }
        let me = ScenarioFixtures.Person(id: "100", username: "reader", displayName: "Reader", avatar: ScenarioArtwork.avatar("reader"))
        let markers: [String: Any] = [
            "home": ["last_read_id": home[markerIndex].id, "version": 1, "updated_at": "2026-01-01T00:00:00.000Z"],
        ]
        let instance: [String: Any] = [
            "domain": ScenarioFixtures.domain,
            "version": "4.4.0",
            "configuration": ["urls": ["streaming": "wss://\(ScenarioFixtures.domain)"]],
        ]
        let account = ScenarioFixtures.json(ScenarioFixtures.account(me))
        guard let instanceURL = URL(string: "https://\(ScenarioFixtures.domain)") else { preconditionFailure("シナリオのサーバーのURLが不正") }
        return ScenarioScript(
            credential: Credential(instance: instanceURL, accessToken: "scenario", clientID: "scenario", clientSecret: "scenario", accountID: me.id, username: me.username),
            responses: [
                "api/v1/accounts/verify_credentials": account,
                "api/v1/accounts/\(me.id)": account,
                "api/v2/instance": ScenarioFixtures.json(instance),
                "api/v1/preferences": ScenarioFixtures.json([String: Any]()),
                "api/v1/markers": ScenarioFixtures.json(markers),
                "api/v1/custom_emojis": ScenarioFixtures.json([Any]()),
            ],
            lists: ["api/v1/timelines/home": home],
            events: [:],
            interval: .milliseconds(300)
        )
    }

    /// 検証の投稿を置く場所（`inject`と同じDocuments/DebugInject）の`gap-reading.json`。
    private static func posts() -> [ScenarioScript.Item] {
        let url = URL.documentsDirectory.appending(path: "DebugInject").appending(fileName: SafeFileName("gap-reading.json"))
        guard let data = try? Data(contentsOf: url), let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            preconditionFailure("gap-reading.jsonを読めない: \(url.path())")
        }
        return array.map { object in
            guard let id = object["id"] as? String else { preconditionFailure("gap-reading.jsonの投稿にIDがない") }
            return ScenarioScript.Item(id: id, json: ScenarioFixtures.json(object))
        }
    }
}
#endif
