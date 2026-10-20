#if DEBUG
import Foundation
import SciaCore
import UIKit

/// デモの台本「流れても、動かない」。ストリーミングで新着が流れてきても、読んでいる位置が動かないことを見せる。
/// 流れはdocs/promo-video.mdにある。起動の引数`-scenario streaming`で選ぶ。
enum StreamingDemoScenario {
    private typealias Person = ScenarioFixtures.Person

    private static let me = person("100", "yuu", "ゆう", "ゆ", .systemIndigo)
    private static let akari = person("101", "akari", "あかり", "灯", .systemOrange)
    private static let minato = person("102", "minato", "湊", "湊", .systemTeal)
    private static let kotori = person("103", "kotori", "ことり", "こ", .systemPink)
    private static let haruno = person("104", "haruno", "春野", "春", .systemGreen)
    private static let sora = person("105", "sora", "そら", "空", .systemBlue)
    private static let tsumugi = person("106", "tsumugi", "つむぎ", "紬", .systemPurple)

    private struct Post: Sendable {
        let minutesAgo: Int
        let person: Person
        let text: String
        var pictures: [ScenarioFixtures.Picture] = []
    }

    /// 新着が流れる場面。名前は`scia-debug://scenario/<名前>`で使う。
    private static let arrivals: [String: [(Person, String)]] = [
        "arrivals-top": [
            (kotori, "パン屋さん、夕方にはもう売り切れてた。明日は朝いちばんに行く"),
            (sora, "いま空を見て。虹が二重になってる"),
            (haruno, "虹、こっちからも見えた！"),
        ],
        "arrivals-reading": [
            (minato, "通知を切って作業したら、1時間で驚くほど進んだ"),
            (akari, "虹の写真、あとで上げます"),
            (tsumugi, "雨のあとの虹、久しぶりに見た"),
            (kotori, "夕焼けもきれいになりそう"),
            (sora, "今日の空、忙しいな"),
        ],
        "arrivals-viewer": [
            (haruno, "買い物の帰りに見たら、まだ少し虹が残ってた"),
            (minato, "今日は早めに寝よう"),
        ],
    ]

    static func make(launchedAt now: Date) -> ScenarioScript {
        let homePosts = homePosts()
        let home = homePosts.enumerated().map { index, post in
            item(status(post, index: index, now: now))
        }
        let walk = status(homePosts[4], index: 4, now: now)
        let notifications = [
            ScenarioFixtures.notification(id: ScenarioFixtures.id(at: now.addingTimeInterval(-30 * 60), sequence: 1), type: "reblog", createdAt: now.addingTimeInterval(-30 * 60), by: sora, status: walk),
            ScenarioFixtures.notification(id: ScenarioFixtures.id(at: now.addingTimeInterval(-40 * 60), sequence: 2), type: "favourite", createdAt: now.addingTimeInterval(-40 * 60), by: kotori, status: status(homePosts[13], index: 13, now: now)),
            ScenarioFixtures.notification(id: ScenarioFixtures.id(at: now.addingTimeInterval(-60 * 60), sequence: 3), type: "follow", createdAt: now.addingTimeInterval(-60 * 60), by: tsumugi, status: nil),
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
            let notification = ScenarioFixtures.notification(id: ScenarioFixtures.id(at: date, sequence: 0), type: "favourite", createdAt: date, by: akari, status: walk)
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
        guard let instanceURL = URL(string: "https://\(ScenarioFixtures.domain)") else { preconditionFailure("台本のサーバーのURLが不正") }
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
        guard let id = object["id"] as? String else { preconditionFailure("台本の要素にIDがない") }
        return ScenarioScript.Item(id: id, json: ScenarioFixtures.json(object))
    }

    private static func person(_ id: String, _ username: String, _ displayName: String, _ initial: String, _ color: UIColor) -> Person {
        Person(id: id, username: username, displayName: displayName, avatar: ScenarioArtwork.avatar(initial, color: color))
    }

    private static func homePosts() -> [Post] {
        let evening = ScenarioArtwork.Landscape(sky: (.systemOrange, .systemPink), sun: .systemYellow, hills: (.systemPurple, UIColor(red: 0.25, green: 0.12, blue: 0.35, alpha: 1)))
        let morning = ScenarioArtwork.Landscape(sky: (UIColor(red: 0.55, green: 0.8, blue: 1, alpha: 1), UIColor(red: 1, green: 0.95, blue: 0.8, alpha: 1)), sun: .white, hills: (.systemGreen, UIColor(red: 0.1, green: 0.4, blue: 0.2, alpha: 1)))
        let night = ScenarioArtwork.Landscape(sky: (UIColor(red: 0.05, green: 0.08, blue: 0.25, alpha: 1), .systemIndigo), sun: UIColor(red: 1, green: 0.95, blue: 0.7, alpha: 1), hills: (UIColor(red: 0.12, green: 0.12, blue: 0.3, alpha: 1), UIColor(red: 0.05, green: 0.05, blue: 0.15, alpha: 1)))
        let afterRain = ScenarioArtwork.Landscape(sky: (UIColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 1), UIColor(red: 0.85, green: 0.9, blue: 0.95, alpha: 1)), sun: UIColor(white: 1, alpha: 0.9), hills: (.systemTeal, UIColor(red: 0.1, green: 0.35, blue: 0.4, alpha: 1)))
        let sea = ScenarioArtwork.Landscape(sky: (.systemCyan, UIColor(red: 0.9, green: 0.97, blue: 1, alpha: 1)), sun: .white, hills: (.systemBlue, UIColor(red: 0.0, green: 0.25, blue: 0.55, alpha: 1)))
        return [
            Post(minutesAgo: 2, person: kotori, text: "駅前に新しいパン屋さんができてた。クロワッサンが軽くて、持っただけで層が分かる"),
            Post(minutesAgo: 4, person: minato, text: "雨上がりの帰り道、アスファルトの匂いで急に夏休みを思い出した"),
            Post(minutesAgo: 7, person: haruno, text: "ベランダのミニトマトが一気に赤くなった。毎朝の楽しみが増えた"),
            Post(minutesAgo: 9, person: sora, text: "コーヒーを淹れている時間が、いちばん頭が静かになる"),
            Post(minutesAgo: 12, person: me, text: "久しぶりに長い散歩。知らない路地に入ると、だいたい猫がいる"),
            Post(minutesAgo: 15, person: akari, text: "週末に撮った写真を整理してたら、空の色が全部ちがって面白かった\n\n夕方、朝、夜、雨上がりの4枚", pictures: [
                ScenarioArtwork.landscape(evening, size: CGSize(width: 1_600, height: 1_200), description: "夕焼けの空と丘"),
                ScenarioArtwork.landscape(morning, size: CGSize(width: 1_200, height: 1_600), description: "朝の空と緑の丘"),
                ScenarioArtwork.landscape(night, size: CGSize(width: 1_600, height: 1_200), description: "夜空に浮かぶ月"),
                ScenarioArtwork.landscape(afterRain, size: CGSize(width: 1_600, height: 900), description: "雨上がりの空"),
            ]),
            Post(minutesAgo: 18, person: tsumugi, text: "図書館の窓際の席、午後の光がちょうどいい"),
            Post(minutesAgo: 22, person: kotori, text: "お昼はパン屋さんのサンドイッチ。卵がたっぷりで幸せ"),
            Post(minutesAgo: 26, person: minato, text: "キーボードのキーキャップを替えた。打つ音がやわらかくなって、文章を書くのが少し楽しい"),
            Post(minutesAgo: 31, person: haruno, text: "朝の電車、窓の外の田んぼが一面の緑で、思わず見とれた"),
            Post(minutesAgo: 35, person: akari, text: "フィルムの現像が上がってきた。待つ時間も含めて好き"),
            Post(minutesAgo: 40, person: sora, text: "夜の散歩で見上げたら、月がやけに大きかった"),
            Post(minutesAgo: 44, person: tsumugi, text: "読みかけの本、あと30ページで終わる。終わってほしくない"),
            Post(minutesAgo: 49, person: me, text: "朝ごはんのトースト、今日は焼き加減が完璧だった"),
            Post(minutesAgo: 53, person: kotori, text: "海まで自転車で。風が気持ちよかった", pictures: [
                ScenarioArtwork.landscape(sea, size: CGSize(width: 1_600, height: 900), description: "青い海と空"),
            ]),
            Post(minutesAgo: 58, person: minato, text: "今週はよく眠れた。それだけで世界が少しやさしい"),
            Post(minutesAgo: 64, person: haruno, text: "近所の公園の紫陽花が色づき始めた"),
            Post(minutesAgo: 70, person: sora, text: "雨の日に聴くプレイリストを作り直した"),
            Post(minutesAgo: 77, person: tsumugi, text: "手帳を新しくした。最初のページに何を書くか、まだ決められない"),
            Post(minutesAgo: 85, person: akari, text: "おはようございます。今日も一日、のんびりいきましょう"),
        ]
    }
}
#endif
