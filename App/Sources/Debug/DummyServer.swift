#if DEBUG
import os
import SciaCore
import UIKit

/// ログインせずに、ダミーのデータでホームと通知の画面に入るための、通信しないサーバー。
/// 資格情報のホストを`dummy.invalid`にしておき、`FaultInjectingTransport`と`FaultInjectingWebSocketConnector`が、宛先がこのホストのときだけここへ回す。
/// ホストで振り分けるので、本物のアカウントの通信には効かない。アバターと画像は端末の中で作るdata URLにして、外へ通信しない。
/// ホームと通知の最初の1ページだけを返し、それより古いものと新しいものは空にする。投稿への操作など、ほかのAPIは404を返す。
enum DummyServer {
    static let host = "dummy.invalid"

    /// ダミーのセッションの資格情報。Keychainには保存しない。
    static var credential: Credential {
        Credential(
            instance: URL(string: "https://\(host)") ?? URL(filePath: "/"),
            accessToken: "dummy",
            clientID: "dummy",
            clientSecret: "dummy",
            accountID: me.id,
            username: me.username
        )
    }

    static func handles(_ url: URL?) -> Bool {
        url?.host() == host
    }

    /// 中身の画像をUIKitで作るため、メインスレッドで作る。
    @MainActor
    static func response(for request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(filePath: "/")
        let path = url.path()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // 最初のページ以外（古い方と新しい方を読むとき）は空にする。
        let isFirstPage = !query.contains { ["max_id", "min_id", "since_id"].contains($0.name) }
        let body: Data? = switch (request.httpMethod ?? "GET", path) {
        // ローカルと連合も、タブを開いたときに空振りしないよう、ホームと同じ投稿を返す。
        case ("GET", "/api/v1/timelines/home"), ("GET", "/api/v1/timelines/public"): isFirstPage ? Content.home : Data("[]".utf8)
        case ("GET", "/api/v2/notifications"): isFirstPage ? Content.notifications : Data(#"{"accounts":[],"statuses":[],"notification_groups":[]}"#.utf8)
        // 保留中の通知の1人分の、その人からの通知。
        case ("GET", "/api/v1/notifications"):
            isFirstPage ? encode(notifications(from: query.first { $0.name == "account_id" }?.value)) : Data("[]".utf8)
        // まとめた通知の「ほか3人」から開く人の一覧。どれも同じ人を返し、続きはない。
        case ("GET", let path) where path.hasSuffix("/favourited_by") || path.hasSuffix("/reblogged_by") || path == "/api/v1/accounts/\(me.id)/followers":
            Content.people
        case (_, "/api/v1/markers"), ("GET", "/api/v1/preferences"): Data("{}".utf8)
        case ("GET", "/api/v1/custom_emojis"), ("GET", "/api/v2/filters"): Data("[]".utf8)
        case ("GET", "/api/v1/accounts/verify_credentials"), ("GET", "/api/v1/accounts/\(me.id)"): Content.me
        // 保留中の通知と通知のフィルタリング。受け入れ、無視、設定の変更は、通信せずに済んだ扱いにする。一覧は読み直すと元に戻る。
        case ("GET", "/api/v2/notifications/policy"): policyBody()
        case ("PATCH", "/api/v2/notifications/policy"):
            applyPolicyForm(request.httpBody)
        case ("GET", "/api/v1/notifications/requests"): isFirstPage ? Content.requests : Data("[]".utf8)
        case ("GET", let path) where path.hasPrefix("/api/v1/notifications/requests/"):
            Content.requestByID[String(path.dropFirst("/api/v1/notifications/requests/".count))]
        case ("POST", let path) where path.hasPrefix("/api/v1/notifications/requests/"): Data("{}".utf8)
        case ("GET", "/api/v2/instance"):
            Data(#"{"version":"4.4.0","configuration":{"urls":{"streaming":"wss://\#(host)"}}}"#.utf8)
        default: nil
        }
        let status = body == nil ? 404 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
            ?? HTTPURLResponse()
        return (body ?? Data(#"{"error":"Record not found"}"#.utf8), response)
    }

    // MARK: - 中身

    private static let me = account("me", "ダミーのあなた", .systemIndigo)
    private static let alice = account("alice", "アリス", .systemPink)
    private static let bob = account("bob", "Bob", .systemGreen)
    private static let carol = account("carol", "キャロル", .systemPurple)
    private static let dave = account("dave", "とても長い表示名のアカウントで名前が収まらない", .systemTeal)

    private static func account(_ username: String, _ displayName: String, _ color: UIColor) -> Account {
        Account(
            id: "dummy-\(username)",
            username: username,
            acct: username == "me" ? username : "\(username)@remote.example",
            displayName: displayName,
            avatar: CatalogFixtures.imageURL(width: 120, height: 120, color: color),
            followersCount: 42,
            followingCount: 7,
            statusesCount: 100
        )
    }

    /// 応答のJSON。画像のdata URLを含んで大きいので、最初に求められたときに1回だけ作る。
    @MainActor
    private enum Content {
        static let home = encode(statuses)
        static let notifications = encode(notificationGroups)
        static let people = encode([alice, bob, carol, dave])
        static let me = encode(DummyServer.me)
        /// 保留中の通知。長い名前と、件数の多い人を含める。
        static let requestList: [(id: String, account: Account, count: Int)] = [("dummy-request-1", bob, 3), ("dummy-request-2", dave, 128), ("dummy-request-3", carol, 1)]
        static let requests = Data("[\(requestList.map { requestJSON($0.id, $0.account, $0.count) }.joined(separator: ","))]".utf8)
        static let requestByID = Dictionary(uniqueKeysWithValues: requestList.map { ($0.id, Data(requestJSON($0.id, $0.account, $0.count).utf8)) })
    }

    private static func requestJSON(_ id: String, _ account: Account, _ count: Int) -> String {
        let date = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        return #"{"id":"\#(id)","created_at":"\#(date)","updated_at":"\#(date)","notifications_count":"\#(count)","account":\#(String(decoding: encode(account), as: UTF8.self))}"#
    }

    /// 通知のフィルタリングの設定。変えた値は、ダミーのセッションの間だけ覚える。
    @MainActor private static var policyValues: [String: String] = [
        "for_not_following": "accept",
        "for_not_followers": "accept",
        "for_new_accounts": "filter",
        "for_private_mentions": "filter",
        "for_limited_accounts": "filter",
    ]

    @MainActor
    private static func policyBody() -> Data {
        let items = policyValues.sorted { $0.key < $1.key }.map { #""\#($0.key)":"\#($0.value)""# }
        let summary = #""summary":{"pending_requests_count":\#(Content.requestList.count),"pending_notifications_count":\#(Content.requestList.map(\.count).reduce(0, +))}"#
        return Data("{\((items + [summary]).joined(separator: ","))}".utf8)
    }

    @MainActor
    private static func applyPolicyForm(_ body: Data?) -> Data {
        var components = URLComponents()
        components.percentEncodedQuery = body.map { String(decoding: $0, as: UTF8.self) }
        for item in components.queryItems ?? [] where policyValues[item.name] != nil {
            policyValues[item.name] = item.value
        }
        return policyBody()
    }

    /// Mastodonと同じく、時刻からIDを作る。新しいほど大きい。
    private static func id(_ number: Int) -> String {
        String((UInt64(1_790_000_000_000) - UInt64(number) * 60_000) << 16)
    }

    private static func date(_ number: Int) -> Date {
        Date.now.addingTimeInterval(-Double(number) * 60 * 7)
    }

    private static func status(
        _ number: Int,
        _ account: Account,
        _ content: String,
        spoiler: String = "",
        media: [MediaAttachment] = [],
        sensitive: Bool = false,
        reblog: Status? = nil,
        favourites: Int = 0
    ) -> Status {
        Status(
            id: id(number),
            createdAt: date(number),
            account: account,
            content: content,
            spoilerText: spoiler,
            url: URL(string: "https://remote.example/@\(account.username)/\(number)"),
            mediaAttachments: media,
            sensitive: sensitive,
            favouritesCount: favourites,
            reblog: reblog
        )
    }

    private static var statuses: [Status] {
        let images = (0..<4).map { index in
            CatalogFixtures.attachment("dummy-image-\(index)", width: 1200, height: index.isMultiple(of: 2) ? 800 : 1200, color: [.systemOrange, .systemBlue, .systemGreen, .systemRed][index])
        }
        let original = status(30, carol, "<p>ブーストされた元の投稿。名前の上に、ブーストした人が出る。</p>", favourites: 12)
        return [
            status(1, alice, "<p>おはようございます。今日は駅前のパン屋が開いていたので、久しぶりにクロワッサンを買った</p>", favourites: 3),
            status(2, bob, "<p>画像が4枚の投稿</p>", media: images),
            status(3, me, "<p>自分の投稿。ダミーのセッションでは、投稿への操作はサーバーに届かない。</p>"),
            status(4, dave, "<p>長い名前の人の投稿。名前が収まらないときの切れ方を見る。</p>"),
            status(5, carol, "<p>注意書きの下の本文</p>", spoiler: "閲覧注意: 映画の結末について"),
            status(6, alice, "<p>閲覧注意の画像</p>", media: [images[0]], sensitive: true),
            status(7, bob, "<p>段落が分かれた投稿。</p><p>" + String(repeating: "ダミーのデータで、ログインせずに画面を確かめる。", count: 4) + "</p>"),
            status(8, alice, "", reblog: original),
            status(9, carol, "<p>縦長の画像</p>", media: [CatalogFixtures.attachment("dummy-tall", width: 600, height: 1800, color: .systemTeal)]),
        ] + (10..<25).map { number in
            status(number, [alice, bob, carol, dave][number % 4], "<p>ダミーの投稿 #\(number)</p>")
        }
    }

    /// `GET /api/v2/notifications`の応答と同じ形。まとめた通知と、まとめない通知を混ぜる。
    private struct GroupedNotifications: Encodable {
        struct Group: Encodable {
            let groupKey: String
            let notificationsCount: Int
            let type: String
            let mostRecentNotificationId: String
            let pageMinId: String
            let pageMaxId: String
            let latestPageNotificationAt: Date
            let sampleAccountIds: [String]
            let statusId: String?
        }

        let accounts: [Account]
        let statuses: [Status]
        let notificationGroups: [Group]
    }

    private static var notificationGroups: GroupedNotifications {
        let mine = status(3, me, "<p>自分の投稿。ダミーのセッションでは、投稿への操作はサーバーに届かない。</p>")
        let mention = status(40, carol, #"<p><span class="h-card"><a href="https://\#(host)/@me" class="u-url mention">@<span>me</span></a></span> ダミーの返信です</p>"#)
        let items: [(MastodonNotification.Kind, [Account], Int, Status?)] = [
            (.favourite, [alice, dave, bob], 5, mine),
            (.reblog, [bob], 1, mine),
            (.mention, [carol], 1, mention),
            (.follow, [dave, bob, carol], 3, nil),
            (.favourite, [dave], 1, mention),
            (.follow, [bob], 1, nil),
        ]
        let groups = items.enumerated().map { index, item in
            let id = "dummy-notification-\(items.count - index)"
            let key = switch item.0 {
            case .favourite, .reblog: "\(item.0.rawValue)-\(item.3?.id ?? "")-\(index)"
            case .follow: "follow-\(index)"
            default: "ungrouped-\(id)"
            }
            return GroupedNotifications.Group(
                groupKey: key,
                notificationsCount: item.2,
                type: item.0.rawValue,
                mostRecentNotificationId: id,
                pageMinId: id,
                pageMaxId: id,
                latestPageNotificationAt: date(index),
                sampleAccountIds: item.1.map(\.id),
                statusId: item.3?.id
            )
        }
        return GroupedNotifications(accounts: [alice, bob, carol, dave], statuses: [mine, mention], notificationGroups: groups)
    }

    /// `GET /api/v1/notifications?account_id=`の応答。通知のタブのダミーのうち、その人が入っている通知を1件ずつにする。
    private static func notifications(from accountID: String?) -> [MastodonNotification] {
        let all = notificationGroups
        return all.notificationGroups.compactMap { group in
            guard let accountID, group.sampleAccountIds.contains(accountID), let account = all.accounts.first(where: { $0.id == accountID }) else { return nil }
            return MastodonNotification(
                id: group.mostRecentNotificationId,
                type: MastodonNotification.Kind(rawValue: group.type),
                createdAt: group.latestPageNotificationAt,
                account: account,
                status: group.statusId.flatMap { id in all.statuses.first { $0.id == id } }
            )
        }
    }

    private static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        do {
            return try encoder.encode(value)
        } catch {
            SciaLog.logger(category: "debug").error("dummy server encode failed: \(error.localizedDescription, privacy: .public)")
            return Data("[]".utf8)
        }
    }
}

/// ダミーのサーバーのストリーミング。pingは通り、何も届かない。
struct DummyWebSocketConnection: WebSocketConnection {
    func receive() async throws -> String {
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
        throw CancellationError()
    }

    func send(_ text: String) async throws {}

    func ping() async throws {}

    func close() {}
}
#endif
