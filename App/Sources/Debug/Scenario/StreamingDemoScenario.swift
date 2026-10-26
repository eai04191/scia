#if DEBUG
import Foundation
import SciaCore
import UIKit

/// デモのシナリオ「流れても、動かない」。ストリーミングで新着が流れてきても、読んでいる位置が動かないことを見せる。
/// 流れはdocs/promo-video.mdにある。起動の引数`-scenario streaming`で選ぶ。
enum StreamingDemoScenario {
    private typealias Person = ScenarioFixtures.Person

    private static let me = person("100", "kyuste", "キュースト")
    private static let fazero = person("101", "fazero", "ファゼーロ")
    private static let rozaro = person("102", "rozaro", "ロザーロ")
    private static let miro = person("103", "miro", "ミーロ")
    private static let temo = person("104", "temo", "テーモ")
    private static let bogant = person("105", "bogant", "ボーガント")
    private static let destupago = person("106", "destupago", "デストゥパーゴ")

    private struct Post: Sendable {
        let minutesAgo: Int
        let person: Person
        let text: String
        var pictures: [ScenarioFixtures.Picture] = []
    }

    /// 新着が流れる場面。名前は`scia-debug://scenario/<名前>`で使う。
    private static let arrivals: [String: [(Person, String)]] = [
        "arrivals-top": [
            (miro, ScenarioDummyText.sentence(from: 3, count: 2)),
            (bogant, ScenarioDummyText.sentence(from: 8, count: 1)),
            (temo, ScenarioDummyText.sentence(from: 0, count: 3)),
        ],
        "arrivals-reading": [
            (rozaro, ScenarioDummyText.sentence(from: 10, count: 2)),
            (fazero, ScenarioDummyText.sentence(from: 5, count: 1)),
            (destupago, ScenarioDummyText.sentence(from: 1, count: 2)),
            (miro, ScenarioDummyText.sentence(from: 13, count: 1)),
            (bogant, ScenarioDummyText.sentence(from: 6, count: 3)),
        ],
        "arrivals-viewer": [
            (temo, ScenarioDummyText.sentence(from: 11, count: 1)),
            (rozaro, ScenarioDummyText.sentence(from: 2, count: 1)),
        ],
    ]

    static func make(launchedAt now: Date) -> ScenarioScript {
        let homePosts = homePosts()
        let home = homePosts.enumerated().map { index, post in
            item(status(post, index: index, now: now))
        }
        let walk = status(homePosts[4], index: 4, now: now)
        let notifications = [
            ScenarioFixtures.notification(id: ScenarioFixtures.id(at: now.addingTimeInterval(-30 * 60), sequence: 1), type: "reblog", createdAt: now.addingTimeInterval(-30 * 60), by: bogant, status: walk),
            ScenarioFixtures.notification(id: ScenarioFixtures.id(at: now.addingTimeInterval(-40 * 60), sequence: 2), type: "favourite", createdAt: now.addingTimeInterval(-40 * 60), by: miro, status: status(homePosts[13], index: 13, now: now)),
            ScenarioFixtures.notification(id: ScenarioFixtures.id(at: now.addingTimeInterval(-60 * 60), sequence: 3), type: "follow", createdAt: now.addingTimeInterval(-60 * 60), by: destupago, status: nil),
        ].map(item)
        var events = arrivals.mapValues { posts in
            { @Sendable (date: Date) in
                posts.enumerated().map { index, entry in
                    let status = ScenarioFixtures.status(id: ScenarioFixtures.id(at: date, sequence: index), createdAt: date, by: entry.0, text: entry.1)
                    return ScenarioFixtures.streamingMessage(event: "update", payload: status)
                }
            }
        }
        let walkPost = homePosts[4]
        events["favourite"] = { @Sendable date in
            let walk = status(walkPost, index: 4, now: now)
            let notification = ScenarioFixtures.notification(id: ScenarioFixtures.id(at: date, sequence: 0), type: "favourite", createdAt: date, by: fazero, status: walk)
            return [ScenarioFixtures.streamingMessage(event: "notification", payload: notification)]
        }
        let markers: [String: Any] = [
            "home": ["last_read_id": home[0].id, "version": 1, "updated_at": "2026-01-01T00:00:00.000Z"],
            "notifications": ["last_read_id": notifications[0].id, "version": 1, "updated_at": "2026-01-01T00:00:00.000Z"],
        ]
        let instance: [String: Any] = [
            "domain": ScenarioFixtures.domain,
            "version": "4.4.0",
            "configuration": ["urls": ["streaming": "wss://\(ScenarioFixtures.domain)"]],
        ]
        let account = ScenarioFixtures.json(ScenarioFixtures.account(me))
        guard let instanceURL = URL(string: "https://\(ScenarioFixtures.domain)") else { preconditionFailure("シナリオのサーバーのURLが不正") }
        return ScenarioScript(
            credential: Credential(
                instance: instanceURL,
                accessToken: "scenario",
                clientID: "scenario",
                clientSecret: "scenario",
                accountID: me.id,
                username: me.username
            ),
            responses: [
                "api/v1/accounts/verify_credentials": account,
                "api/v1/accounts/\(me.id)": account,
                "api/v2/instance": ScenarioFixtures.json(instance),
                "api/v1/preferences": ScenarioFixtures.json([String: Any]()),
                "api/v1/markers": ScenarioFixtures.json(markers),
                "api/v1/custom_emojis": ScenarioFixtures.json([Any]()),
            ],
            lists: [
                "api/v1/timelines/home": home,
                "api/v1/notifications": notifications,
            ],
            events: events,
            interval: .milliseconds(300)
        )
    }

    /// 新しい順。分の境目をまたがないよう、時刻は起動した時点から「分」ちょうどより1秒前にずらす。
    /// 相対時刻の表示は分の切り捨てなので、起動してから59秒は同じ表示のまま撮れる。
    private static func status(_ post: Post, index: Int, now: Date) -> [String: Any] {
        let createdAt = now.addingTimeInterval(-Double(post.minutesAgo * 60) - 1)
        return ScenarioFixtures.status(
            id: ScenarioFixtures.id(at: createdAt, sequence: index),
            createdAt: createdAt,
            by: post.person,
            text: post.text,
            pictures: post.pictures,
            favourites: post.pictures.isEmpty ? 2 : 14
        )
    }

    private static func item(_ object: [String: Any]) -> ScenarioScript.Item {
        guard let id = object["id"] as? String else { preconditionFailure("シナリオの要素にIDがない") }
        return ScenarioScript.Item(id: id, json: ScenarioFixtures.json(object))
    }

    private static func person(_ id: String, _ username: String, _ displayName: String) -> Person {
        Person(id: id, username: username, displayName: displayName, avatar: ScenarioArtwork.avatar(username))
    }

    private static func homePosts() -> [Post] {
        [
            Post(minutesAgo: 2, person: miro, text: ScenarioDummyText.sentence(from: 0, count: 2)),
            Post(minutesAgo: 4, person: rozaro, text: ScenarioDummyText.sentence(from: 2, count: 1)),
            Post(minutesAgo: 7, person: temo, text: ScenarioDummyText.sentence(from: 3, count: 3)),
            Post(minutesAgo: 9, person: bogant, text: ScenarioDummyText.sentence(from: 6, count: 1)),
            Post(minutesAgo: 12, person: me, text: ScenarioDummyText.sentence(from: 7, count: 2)),
            Post(minutesAgo: 15, person: fazero, text: ScenarioDummyText.sentence(from: 9, count: 3), pictures: [
                ScenarioArtwork.photo("photo-1", size: CGSize(width: 1_600, height: 1_200), description: "写真1"),
                ScenarioArtwork.photo("photo-2", size: CGSize(width: 1_200, height: 1_600), description: "写真2"),
                ScenarioArtwork.photo("photo-3", size: CGSize(width: 1_600, height: 1_200), description: "写真3"),
                ScenarioArtwork.photo("photo-4", size: CGSize(width: 1_600, height: 900), description: "写真4"),
            ]),
            Post(minutesAgo: 18, person: destupago, text: ScenarioDummyText.sentence(from: 13, count: 1)),
            Post(minutesAgo: 22, person: miro, text: ScenarioDummyText.sentence(from: 14, count: 2)),
            Post(minutesAgo: 26, person: rozaro, text: ScenarioDummyText.sentence(from: 1, count: 3)),
            Post(minutesAgo: 31, person: temo, text: ScenarioDummyText.sentence(from: 4, count: 2)),
            Post(minutesAgo: 35, person: fazero, text: ScenarioDummyText.sentence(from: 6, count: 1)),
            Post(minutesAgo: 40, person: bogant, text: ScenarioDummyText.sentence(from: 7, count: 2)),
            Post(minutesAgo: 44, person: destupago, text: ScenarioDummyText.sentence(from: 9, count: 3)),
            Post(minutesAgo: 49, person: me, text: ScenarioDummyText.sentence(from: 12, count: 2)),
            Post(minutesAgo: 53, person: miro, text: ScenarioDummyText.sentence(from: 13, count: 2), pictures: [
                ScenarioArtwork.photo("photo-5", size: CGSize(width: 1_600, height: 900), description: "写真5"),
            ]),
            Post(minutesAgo: 58, person: rozaro, text: ScenarioDummyText.sentence(from: 0, count: 1)),
            Post(minutesAgo: 64, person: temo, text: ScenarioDummyText.sentence(from: 1, count: 2)),
            Post(minutesAgo: 70, person: bogant, text: ScenarioDummyText.sentence(from: 3, count: 3)),
            Post(minutesAgo: 77, person: destupago, text: ScenarioDummyText.sentence(from: 6, count: 1)),
            Post(minutesAgo: 85, person: fazero, text: ScenarioDummyText.sentence(from: 7, count: 2)),
        ]
    }
}
#endif
