public import Foundation
import os

/// ログイン済みアカウントとしてMastodon APIを呼ぶ。
public struct MastodonClient: Sendable {
    public let credential: Credential
    private let http: HTTPClient
    private let rateLimit: RateLimitGate
    private let features: FeatureAvailability
    private let requestLog: RequestLog
    /// エラーの応答が示した再開の時刻を、待つ長さに直すための今の日付。
    private let now: @Sendable () -> Date
    /// 再試行までと、メディアの処理が終わるまでの待ちを数える。テストでは手で進める時計を渡す。
    private let clock: any Clock<Duration>
    private static let logger = SciaLog.logger(category: "network")

    /// - Parameters:
    ///   - rateLimit: 429や503で止められたときに、自動の通信を控える門。セッションの中で共有する。
    ///   - features: 使えないと分かった機能を、セッションの間だけ止める。セッションの中で共有する。
    ///   - retry: 一時的な失敗で送り直す回数と間隔。
    ///   - requestLog: 失敗の記録。セッションの中で共有する。
    public init(
        credential: Credential,
        transport: any HTTPTransport,
        rateLimit: RateLimitGate = RateLimitGate(),
        features: FeatureAvailability = FeatureAvailability(),
        retry: RetryPolicy = .standard,
        requestLog: RequestLog = RequestLog(includesBody: false),
        clock: any Clock<Duration> = SystemTime.clock,
        now: @escaping @Sendable () -> Date = SystemTime.now
    ) {
        self.clock = clock
        self.credential = credential
        http = HTTPClient(transport: transport, retry: retry, clock: clock, now: now)
        self.rateLimit = rateLimit
        self.features = features
        self.requestLog = requestLog
        self.now = now
    }

    /// 429や503で止められ、自動の通信を控えている間の再開の時刻。控えていなければnil。
    public func automaticRequestsPausedUntil() async -> Date? {
        await rateLimit.pausedUntil
    }

    /// https://docs.joinmastodon.org/methods/timelines/#home
    public func homeTimeline(_ query: TimelineQuery) async throws -> TimelinePage {
        let (list, response) = try await get(ElementList<Status>.self, path: "api/v1/timelines/home", query: query.queryItems)
        // ホームの再生成中は206が返り、中身が空でも終端とは限らない。
        return TimelinePage(statuses: list.elements, unreadable: list.unreadable, isRegenerating: response.statusCode == 206)
    }

    /// 公開タイムライン。
    /// - Parameter localOnly: このサーバーの投稿だけを返す（ローカルタイムライン）。falseなら、このサーバーが知っている公開の投稿をすべて返す（連合タイムライン）。
    /// https://docs.joinmastodon.org/methods/timelines/#public
    public func publicTimeline(_ query: TimelineQuery, localOnly: Bool) async throws -> TimelinePage {
        let items = query.queryItems + (localOnly ? [URLQueryItem(name: "local", value: "true")] : [])
        let list = try await get(ElementList<Status>.self, path: "api/v1/timelines/public", query: items).0
        return TimelinePage(statuses: list.elements, unreadable: list.unreadable, isRegenerating: false)
    }

    /// 通知を、サーバーがまとめた形で新しい順に返す。まとめるのは`MastodonNotification.Kind.grouped`の種類だけにする。
    /// 1回に読めるまとまりの数の上限は80。
    /// v2のないサーバー（Mastodon 4.2以前）では、v1でまとめずに読む。決まりはdocs/notification-display.mdの「まとめて表示する」にある。
    /// https://docs.joinmastodon.org/methods/grouped_notifications/#get-grouped
    public func notifications(_ query: TimelineQuery) async throws -> NotificationPage {
        let grouping = MastodonNotification.Kind.grouped.map { URLQueryItem(name: "grouped_types[]", value: $0.rawValue) }
        do {
            return try await get(GroupedNotificationsResults.self, path: "api/v2/notifications", query: query.queryItems + grouping, feature: .groupedNotifications).0.page
        } catch is FeatureUnavailable {
            return try await ungroupedNotifications(query, filter: [])
        }
    }

    /// その人からの通知を、保留している通知も含めて、まとめずに新しい順に返す。
    /// v2はdocsに`account_id`があるが、Mastodonのサーバーは読まずにほかの人の通知も返すため、Mastodonのwebと同じくv1で読む。
    /// v1は`account_id`を渡すと、`include_filtered`がなくても保留した通知を含める（`Notification.browserable`）。
    /// https://docs.joinmastodon.org/methods/notifications/#get
    public func notifications(_ query: TimelineQuery, from accountID: String) async throws -> NotificationPage {
        try await ungroupedNotifications(query, filter: [URLQueryItem(name: "account_id", value: accountID)])
    }

    /// v1で、通知をまとめずに読む。どの通知もそれだけを消せるよう、まとまりのキーを`ungrouped-<通知のID>`にする。
    /// https://docs.joinmastodon.org/methods/notifications/#get
    private func ungroupedNotifications(_ query: TimelineQuery, filter: [URLQueryItem]) async throws -> NotificationPage {
        let list = try await get(ElementList<MastodonNotification>.self, path: "api/v1/notifications", query: query.queryItems + filter).0
        let notifications = list.elements.map { MastodonNotification(id: $0.id, type: $0.type, createdAt: $0.createdAt, account: $0.account, status: $0.status, reactionEmoji: $0.reactionEmoji) }
        return NotificationPage(notifications: notifications, unreadable: list.unreadable)
    }

    /// 通知のフィルタリングの設定と、保留中の通知の数。
    /// https://docs.joinmastodon.org/methods/notifications/#get-policy
    public func notificationPolicy() async throws -> NotificationPolicy {
        try await get(NotificationPolicy.self, path: "api/v2/notifications/policy", query: [], feature: .notificationFilter).0
    }

    /// 通知のフィルタリングの設定のうち、渡した項目だけを変える。変えたあとの設定を返す。
    /// https://docs.joinmastodon.org/methods/notifications/#update-the-filtering-policy-for-notifications
    public func updateNotificationPolicy(_ changes: [NotificationPolicy.Item: NotificationPolicy.Value]) async throws -> NotificationPolicy {
        let form = NotificationPolicy.Item.allCases.compactMap { item in
            changes[item]?.rawValue.map { URLQueryItem(name: item.rawValue, value: $0) }
        }
        return try await send(formRequest(method: "PATCH", path: "api/v2/notifications/policy", form: form), decoding: NotificationPolicy.self, feature: .notificationFilter).0
    }

    /// 保留中の通知を、人ごとのまとまりでサーバーが返す順に返す。1回に読める件数の上限は80件。
    /// - Parameter maxID: 前のページの`NotificationRequestPage.nextMaxID`。nilなら最初のページ。
    /// https://docs.joinmastodon.org/methods/notifications/#get-requests
    public func notificationRequests(maxID: String?, limit: Int) async throws -> NotificationRequestPage {
        let query = [URLQueryItem(name: "limit", value: String(limit))] + (maxID.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
        let (requests, response) = try await get(ElementList<NotificationRequest>.self, path: "api/v1/notifications/requests", query: query, feature: .notificationFilter)
        let link = response.value(forHTTPHeaderField: "Link").map(LinkHeader.init)
        return NotificationRequestPage(requests: requests.elements, nextMaxID: link?.queryValue("max_id", of: "next"))
    }

    /// 保留中の通知の1人分のまとまり。
    /// https://docs.joinmastodon.org/methods/notifications/#get-one-request
    public func notificationRequest(_ id: String) async throws -> NotificationRequest {
        let key = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        return try await get(NotificationRequest.self, path: "api/v1/notifications/requests/\(key)", query: []).0
    }

    /// 保留中の通知に答える。受け入れると、サーバーはあとで保留していた通知を通知の一覧に戻し、終えたらストリーミングの`notifications_merged`で知らせる。
    /// 応答の中身は使わない。
    /// https://docs.joinmastodon.org/methods/notifications/#accept-request
    /// https://docs.joinmastodon.org/methods/notifications/#dismiss-request
    public func answerNotificationRequest(_ id: String, _ decision: NotificationRequestDecision) async throws {
        let action = switch decision {
        case .accept: "accept"
        case .dismiss: "dismiss"
        }
        let key = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        _ = try await send(formRequest(method: "POST", path: "api/v1/notifications/requests/\(key)/\(action)", form: []))
    }

    /// 受け入れた保留中の通知を、サーバーが通知の一覧に戻し終えたか。
    /// https://docs.joinmastodon.org/methods/notifications/#requests-merged
    public func notificationRequestsMerged() async throws -> Bool {
        try await get(MergedState.self, path: "api/v1/notifications/requests/merged", query: [], feature: .notificationFilter).0.merged
    }

    /// 既読位置。まだ保存されていなければnil。
    /// https://docs.joinmastodon.org/methods/markers/#get
    public func marker(for timeline: MarkerTimeline) async throws -> String? {
        let (markers, _) = try await get([String: Marker].self, path: "api/v1/markers", query: [URLQueryItem(name: "timeline[]", value: timeline.rawValue)], feature: .markers)
        return markers[timeline.rawValue]?.lastReadId
    }

    /// 既読位置を保存する。他の端末と同時に保存して競合すると409が返る。
    /// https://docs.joinmastodon.org/methods/markers/#create
    public func saveMarker(for timeline: MarkerTimeline, lastReadID: String) async throws {
        _ = try await post([String: Marker].self, path: "api/v1/markers", form: [URLQueryItem(name: "\(timeline.rawValue)[last_read_id]", value: lastReadID)], feature: .markers)
    }

    /// ストリーミングAPIの接続先。REST APIと別のホストのことがある。
    /// https://docs.joinmastodon.org/methods/instance/#v2
    func streamingURLFromV2() async throws -> URL {
        struct Instance: Decodable {
            struct Configuration: Decodable {
                struct URLs: Decodable {
                    let streaming: URL
                }
                let urls: URLs
            }
            let configuration: Configuration
        }
        return try await get(Instance.self, path: "api/v2/instance", query: [], feature: .instanceV2).0.configuration.urls.streaming
    }

    /// v2の`instance`がないサーバーのための、v1の接続先。
    /// https://docs.joinmastodon.org/entities/V1_Instance/#streaming_api
    func streamingURLFromV1() async throws -> URL {
        struct Instance: Decodable {
            struct URLs: Decodable {
                let streamingApi: URL
            }
            let urls: URLs
        }
        return try await get(Instance.self, path: "api/v1/instance", query: []).0.urls.streamingApi
    }

    /// サーバーの版。Mastodon以外のサーバーは、互換の版のあとに自分の名前と版を書くことが多い。記録に残し、原因を絞るのに使う。
    /// https://docs.joinmastodon.org/entities/Instance/#version
    public func serverVersion() async throws -> String {
        struct Instance: Decodable {
            let version: String
        }
        do {
            return try await get(Instance.self, path: "api/v2/instance", query: [], feature: .instanceV2).0.version
        } catch let error as MastodonAPIError where error.isUnauthorized {
            throw error
        } catch {
            return try await get(Instance.self, path: "api/v1/instance", query: []).0.version
        }
    }

    /// サーバーの、Mastodonにない機能の有無。Fedibirdの拡張で、`api/v1/instance`の`fedibird_capabilities`で決める。
    /// Fedibirdとkmyblueはv1に必ず返すので、v2は読まない。項目がないサーバーは、Mastodonと同じとみなす。
    public func serverCapabilities() async throws -> ServerCapabilities {
        struct Instance: Decodable {
            let fedibirdCapabilities: [String]?
        }
        let capabilities = try await get(Instance.self, path: "api/v1/instance", query: []).0.fedibirdCapabilities ?? []
        return ServerCapabilities(fedibirdCapabilities: capabilities)
    }

    /// https://docs.joinmastodon.org/methods/instance/#v2
    public func instanceConfiguration() async throws -> InstanceConfiguration {
        struct Instance: Decodable {
            struct Configuration: Decodable {
                struct Statuses: Decodable {
                    let maxCharacters: ServerLimit?
                    let maxMediaAttachments: ServerLimit?
                    let charactersReservedPerUrl: ServerLimit?
                }
                struct Accounts: Decodable {
                    let maxDisplayNameLength: ServerLimit?
                    let maxNoteLength: ServerLimit?
                    let maxProfileFields: ServerLimit?
                    let profileFieldNameLimit: ServerLimit?
                    let profileFieldValueLimit: ServerLimit?
                    let maxFeaturedTags: ServerLimit?
                }
                struct Polls: Decodable {
                    let maxOptions: ServerLimit?
                    let maxCharactersPerOption: ServerLimit?
                    let minExpiration: ServerLimit?
                    let maxExpiration: ServerLimit?
                }
                struct MediaAttachments: Decodable {
                    let supportedMimeTypes: [String]?
                    let descriptionLimit: ServerLimit?
                    let imageSizeLimit: ServerLimit?
                    let imageMatrixLimit: ServerLimit?
                    let videoSizeLimit: ServerLimit?
                    let videoMatrixLimit: ServerLimit?
                    let videoFrameRateLimit: ServerLimit?
                }
                let accounts: Accounts?
                let statuses: Statuses?
                let mediaAttachments: MediaAttachments?
                let polls: Polls?
            }
            let configuration: Configuration
        }
        let configuration = try await get(Instance.self, path: "api/v2/instance", query: [], feature: .instanceV2).0.configuration
        // 投稿の設定を返さないサーバーには、Mastodonの既定値を使う。
        // 代替テキストの上限は4.4.0から返るが、それより前のMastodonも1500文字で検証している。
        let maxCharacters = configuration.statuses?.maxCharacters?.value ?? 500
        // URLの予約文字数は、文字数を数えるたびにその長さの文字列を作る。投稿の上限より長い予約は、URLを1つ書くだけで送れなくなる意味のない設定なので、既定値にする。
        let charactersReservedPerURL = configuration.statuses?.charactersReservedPerUrl?.value.flatMap { $0 <= maxCharacters ? $0 : nil } ?? 23
        return InstanceConfiguration(
            maxCharacters: maxCharacters,
            charactersReservedPerURL: charactersReservedPerURL,
            maxMediaAttachments: configuration.statuses?.maxMediaAttachments?.value ?? 4,
            mediaDescriptionLimit: configuration.mediaAttachments?.descriptionLimit?.value ?? 1500,
            supportedMediaTypes: configuration.mediaAttachments?.supportedMimeTypes,
            profileLimits: ProfileLimits(
                displayName: configuration.accounts?.maxDisplayNameLength?.value ?? ProfileLimits.beforeMastodon46.displayName,
                note: configuration.accounts?.maxNoteLength?.value ?? ProfileLimits.beforeMastodon46.note,
                fields: configuration.accounts?.maxProfileFields?.value ?? ProfileLimits.beforeMastodon46.fields,
                fieldName: configuration.accounts?.profileFieldNameLimit?.value ?? ProfileLimits.beforeMastodon46.fieldName,
                fieldValue: configuration.accounts?.profileFieldValueLimit?.value ?? ProfileLimits.beforeMastodon46.fieldValue,
                featuredTags: configuration.accounts?.maxFeaturedTags?.value
            ),
            pollLimits: Self.pollLimits(configuration.polls.map { ($0.maxOptions?.value, $0.maxCharactersPerOption?.value, $0.minExpiration?.value, $0.maxExpiration?.value) }),
            // 上限はサーバーごとに変えられていることが多いので、返さない項目をMastodonの既定値で補わない。
            mediaLimits: MediaLimits(
                imageSizeLimit: configuration.mediaAttachments?.imageSizeLimit?.value,
                imageMatrixLimit: configuration.mediaAttachments?.imageMatrixLimit?.value,
                videoSizeLimit: configuration.mediaAttachments?.videoSizeLimit?.value,
                videoMatrixLimit: configuration.mediaAttachments?.videoMatrixLimit?.value,
                videoFrameRateLimit: configuration.mediaAttachments?.videoFrameRateLimit?.value
            )
        )
    }

    /// 投票の上限。返さない項目はMastodonの既定値で補う。下限が上限を超える値は読めないものとして、既定値にする。
    static func pollLimits(_ polls: (maxOptions: Int?, maxCharactersPerOption: Int?, minExpiration: Int?, maxExpiration: Int?)?) -> PollLimits {
        let fallback = PollLimits.mastodonDefault
        let minExpiration = polls?.minExpiration ?? fallback.expirationRange.lowerBound
        let maxExpiration = polls?.maxExpiration ?? fallback.expirationRange.upperBound
        return PollLimits(
            maxOptions: max(polls?.maxOptions ?? fallback.maxOptions, 2),
            maxCharactersPerOption: polls?.maxCharactersPerOption ?? fallback.maxCharactersPerOption,
            expirationRange: minExpiration <= maxExpiration ? minExpiration...maxExpiration : fallback.expirationRange
        )
    }

    /// ユーザーがアカウントの設定で決めた、クライアントをまたいで使う設定。
    /// https://docs.joinmastodon.org/methods/preferences/#get
    public func preferences() async throws -> ServerPreferences {
        struct Preferences: Decodable {
            let visibility: Status.Visibility?
            let sensitive: Bool?
            let expandsSpoilers: Bool?
            let language: String?
            let autoplaysAnimations: Bool?

            private enum CodingKeys: String, CodingKey {
                case visibility = "posting:default:visibility"
                case sensitive = "posting:default:sensitive"
                case language = "posting:default:language"
                case expandsSpoilers = "reading:expand:spoilers"
                case autoplaysAnimations = "reading:autoplay:gifs"
            }
        }
        // キーにコロンを含むため、スネークケースからの変換を通さずに読む。
        let request = URLRequest(url: credential.instance.appending(path: "api/v1/preferences"))
        let (data, response) = try await send(request, feature: .preferences)
        let preferences = try decode(Preferences.self, from: data, of: response, for: request, using: JSONDecoder())
        // 返さない項目は、Mastodonの既定値を使う。
        // 既定の言語は、決めていなければnullか空で返る。
        return ServerPreferences(
            defaultVisibility: preferences.visibility ?? .public,
            defaultSensitive: preferences.sensitive ?? false,
            expandsSpoilers: preferences.expandsSpoilers ?? false,
            defaultLanguage: preferences.language.flatMap { $0.isEmpty ? nil : $0 },
            autoplaysAnimations: preferences.autoplaysAnimations ?? false
        )
    }

    /// サーバーが投稿の言語として受け付ける言語。並びはサーバーが返すまま。
    /// https://github.com/mastodon/mastodon/blob/main/app/controllers/api/v1/instances/languages_controller.rb
    public func postingLanguages() async throws -> [PostingLanguage] {
        try await get([PostingLanguage].self, path: "api/v1/instance/languages", query: []).0
    }

    // MARK: - 投稿への操作

    /// お気に入りに登録し、登録後の投稿を返す。
    /// 一度に読める投稿の数。Mastodonは、これより多く求めると422を返す。
    public static let multipleStatusesLimit = 20

    /// 投稿をまとめて読む。消えた投稿と見られない投稿は返らず、読めない投稿は除く。
    /// リンクカードの取り直しに使い、リクエストを間隔ごとに1回に収めるため、一時的な失敗でも送り直さず、次の取り直しに任せる。
    /// https://docs.joinmastodon.org/methods/statuses/#index
    public func statuses(_ ids: [Status.ID]) async throws -> [Status] {
        let query = ids.map { URLQueryItem(name: "id[]", value: $0) }
        return try await get(ElementList<Status>.self, path: "api/v1/statuses", query: query, feature: .multipleStatuses, retries: false).0.elements
    }

    /// https://docs.joinmastodon.org/methods/statuses/#favourite
    public func favourite(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/favourite", form: []).0
    }

    /// https://docs.joinmastodon.org/methods/statuses/#unfavourite
    public func unfavourite(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/unfavourite", form: []).0
    }

    /// 投票する。複数選べない投票でも、選んだ選択肢を配列で送る。投票し直しはできず、サーバーは2度目の投票や自分の投票への投票を422で断る。
    /// https://docs.joinmastodon.org/methods/polls/#vote
    public func vote(_ pollID: Poll.ID, choices: [Int]) async throws -> Poll {
        let form = choices.map { URLQueryItem(name: "choices[]", value: String($0)) }
        return try await post(Poll.self, path: "api/v1/polls/\(pollID)/votes", form: form).0
    }

    /// https://docs.joinmastodon.org/methods/polls/#get
    public func poll(_ pollID: Poll.ID) async throws -> Poll {
        try await get(Poll.self, path: "api/v1/polls/\(pollID)", query: []).0
    }

    /// https://docs.joinmastodon.org/methods/statuses/#bookmark
    public func bookmark(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/bookmark", form: []).0
    }

    /// https://docs.joinmastodon.org/methods/statuses/#unbookmark
    public func unbookmark(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/unbookmark", form: []).0
    }

    /// 投稿の会話をミュートし、その会話の通知を受け取らないようにする。サーバーは自分が会話に加わっているかを確かめない。
    /// https://docs.joinmastodon.org/methods/statuses/#mute
    public func muteConversation(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/mute", form: []).0
    }

    /// https://docs.joinmastodon.org/methods/statuses/#unmute
    public func unmuteConversation(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/unmute", form: []).0
    }

    /// 自分の投稿をプロフィールに固定する。固定できる数を超えると、サーバーは422を返す。
    /// https://docs.joinmastodon.org/methods/statuses/#pin
    public func pin(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/pin", form: []).0
    }

    /// https://docs.joinmastodon.org/methods/statuses/#unpin
    public func unpin(_ statusID: String) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses/\(statusID)/unpin", form: []).0
    }

    /// ブーストし、ブーストした元の投稿を返す。APIはブーストそのものを返すため、中の元の投稿を取り出す。
    /// https://docs.joinmastodon.org/methods/statuses/#boost
    public func reblog(_ statusID: String, visibility: ReblogVisibility = .accountDefault) async throws -> Status {
        let form = visibility.parameter.map { [URLQueryItem(name: "visibility", value: $0)] } ?? []
        let boost = try await post(Status.self, path: "api/v1/statuses/\(statusID)/reblog", form: form).0
        return boost.reblog ?? boost
    }

    /// ブーストを取り消し、元の投稿を返す。
    /// https://docs.joinmastodon.org/methods/statuses/#unreblog
    public func unreblog(_ statusID: String) async throws -> Status {
        let status = try await post(Status.self, path: "api/v1/statuses/\(statusID)/unreblog", form: []).0
        return status.reblog ?? status
    }

    /// 投稿する。同じ下書きを送り直しても二重に投稿されないよう、下書きごとの`Idempotency-Key`を付ける。
    /// 添付ファイルが済んでいなければ送らずに`StatusPostError.attachmentsNotReady`を投げる。
    /// サーバーが内容を拒んだら、422の`MastodonAPIError`を投げる。
    /// https://docs.joinmastodon.org/methods/statuses/#create
    public func postStatus(_ draft: StatusDraft) async throws -> Status {
        try await post(Status.self, path: "api/v1/statuses", form: try postForm(of: draft), headers: ["Idempotency-Key": draft.idempotencyKey]).0
    }

    /// `date`に投稿するよう予約する。投稿と同じく、下書きごとの`Idempotency-Key`を付ける。サーバーは予約にも同じキーで二重に作らない。
    /// 今から5分以内の日時は、サーバーが422の`MastodonAPIError`で断る。過去の日時はすぐ投稿されてしまうため、送る前に`ScheduledPosting.accepts`で確かめる。
    /// https://docs.joinmastodon.org/methods/statuses/#create
    public func scheduleStatus(_ draft: StatusDraft, at date: Date) async throws -> ScheduledStatus {
        let form = try postForm(of: draft) + [URLQueryItem(name: "scheduled_at", value: date.formatted(.iso8601))]
        return try await post(ScheduledStatus.self, path: "api/v1/statuses", form: form, headers: ["Idempotency-Key": draft.idempotencyKey]).0
    }

    /// 投稿と予約で送るフォーム。
    private func postForm(of draft: StatusDraft) throws -> [URLQueryItem] {
        guard let mediaIDs = draft.mediaIDs else { throw StatusPostError.attachmentsNotReady }
        var form = [
            URLQueryItem(name: "status", value: draft.text),
            URLQueryItem(name: "visibility", value: draft.visibility.rawValue),
            // 付けないときも送る。送らなければ、サーバーはアカウントの「既定で閲覧注意にする」に従い、注意書きの欄を閉じた投稿まで閲覧注意にするため。
            URLQueryItem(name: "sensitive", value: draft.sensitive ? "true" : "false"),
        ]
        if !draft.spoilerText.isEmpty {
            form.append(URLQueryItem(name: "spoiler_text", value: draft.spoilerText))
        }
        if let inReplyToID = draft.inReplyToID {
            form.append(URLQueryItem(name: "in_reply_to_id", value: inReplyToID))
        }
        if let quotedStatusID = draft.quotedStatusID {
            form.append(URLQueryItem(name: "quoted_status_id", value: quotedStatusID))
        }
        // 送らなければ、サーバーはアカウントの既定の言語、なければweb UIの表示言語にする。
        if let language = draft.language {
            form.append(URLQueryItem(name: "language", value: language))
        }
        form += mediaIDs.map { URLQueryItem(name: "media_ids[]", value: $0) }
        if let poll = draft.poll {
            form += poll.formItems
        }
        return form
    }

    /// 予約した投稿をすべて返す。並びはサーバーが返すまま（予約した新しい順）。続きを`Link`ヘッダーで読み、最後まで読み切ってから返す。
    /// 予約は1人300件までで、1回に読める件数の上限は40件。
    /// https://docs.joinmastodon.org/methods/scheduled_statuses/#get
    public func scheduledStatuses() async throws -> [ScheduledStatus] {
        try await allPages(path: "api/v1/scheduled_statuses", limit: 40) { path, query in
            try await get([ScheduledStatus].self, path: path, query: query)
        }
    }

    /// 続きを`Link`ヘッダーの`next`の`max_id`で読み、最後まで読み切ってから返す。途中で読めなければ投げる。
    /// - Parameter page: `path`を`query`で読み、そのページの要素と応答を返す。
    private func allPages<Element>(
        path: String,
        limit: Int,
        page: (String, [URLQueryItem]) async throws -> ([Element], HTTPURLResponse)
    ) async throws -> [Element] {
        var elements: [Element] = []
        var maxID: String?
        var readMaxIDs: Set<String> = []
        repeat {
            let query = [URLQueryItem(name: "limit", value: String(limit))] + (maxID.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
            let (read, response) = try await page(path, query)
            elements += read
            let next = response.value(forHTTPHeaderField: "Link").map(LinkHeader.init)?.queryValue("max_id", of: "next")
            // 読んだ位置を返すサーバー（同じ位置を返し続ける、位置が循環する）で、同じページを読み続けないよう止める。
            if let maxID { readMaxIDs.insert(maxID) }
            maxID = next.flatMap { readMaxIDs.contains($0) || read.isEmpty ? nil : $0 }
        } while maxID != nil
        return elements
    }

    /// 予約の日時を変える。中身は変えられない。今から5分以内の日時は、サーバーが422で断る。
    /// https://docs.joinmastodon.org/methods/scheduled_statuses/#update
    public func rescheduleStatus(_ id: ScheduledStatus.ID, to date: Date) async throws -> ScheduledStatus {
        try await send(formRequest(method: "PUT", path: "api/v1/scheduled_statuses/\(id)", form: [URLQueryItem(name: "scheduled_at", value: date.formatted(.iso8601))]), decoding: ScheduledStatus.self).0
    }

    /// 予約を取り消す。応答の中身は使わない。もう投稿されたか取り消した予約なら、404の`MastodonAPIError`を投げる。
    /// https://docs.joinmastodon.org/methods/scheduled_statuses/#cancel
    public func cancelScheduledStatus(_ id: ScheduledStatus.ID) async throws {
        var request = URLRequest(url: credential.instance.appending(path: "api/v1/scheduled_statuses/\(id)"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// 編集の元にする、投稿を書いたときの本文と注意書き。
    /// https://docs.joinmastodon.org/methods/statuses/#source
    public func statusSource(_ statusID: Status.ID) async throws -> StatusSource {
        try await get(StatusSource.self, path: "api/v1/statuses/\(statusID)/source", query: []).0
    }

    /// 投稿を1件読む。スレッドを読み直すときに、押した投稿の編集を取り込むのに使う。
    /// https://docs.joinmastodon.org/methods/statuses/#get
    public func status(_ statusID: Status.ID) async throws -> Status {
        try await get(Status.self, path: "api/v1/statuses/\(statusID)", query: []).0
    }

    /// 投稿を1件読み、応答の本文を読まずにそのまま返す。投稿のメニューの「APIの応答」で、サーバーが付けた値を確かめるのに使う。
    /// https://docs.joinmastodon.org/methods/statuses/#get
    public func statusResponse(_ statusID: Status.ID) async throws -> Data {
        try await send(URLRequest(url: credential.instance.appending(path: "api/v1/statuses/\(statusID)"))).0
    }

    /// 投稿の前後の会話。スレッドの画面に使う。
    /// https://docs.joinmastodon.org/methods/statuses/#context
    public func statusContext(_ statusID: Status.ID) async throws -> StatusContext {
        try await get(StatusContext.self, path: "api/v1/statuses/\(statusID)/context", query: []).0
    }

    /// 投稿の編集履歴。最初の投稿から今の投稿までの版を、古い順に返す。
    /// https://docs.joinmastodon.org/methods/statuses/#history
    public func statusHistory(_ statusID: Status.ID) async throws -> [StatusRevision] {
        try await get([StatusRevision].self, path: "api/v1/statuses/\(statusID)/history", query: []).0
    }

    /// 自分の投稿を`draft`の内容に編集し、編集したあとの投稿を返す。`target`は`draft.editing`。
    /// 添付ファイルが済んでいなければ送らずに`StatusPostError.attachmentsNotReady`を投げる。
    /// https://docs.joinmastodon.org/methods/statuses/#edit
    public func editStatus(_ target: StatusEditTarget, to draft: StatusDraft, now: Date = SystemTime.now()) async throws -> Status {
        guard let form = draft.editForm(poll: target.poll, now: now) else { throw StatusPostError.attachmentsNotReady }
        return try await send(formRequest(method: "PUT", path: "api/v1/statuses/\(target.statusID)", form: form), decoding: Status.self).0
    }

    /// 自分の投稿を削除する。応答の中身は使わない。
    /// `deleteMedia`なら添付もすぐ消す。送らないと、サーバーは削除して書き直すために、添付を1日ほど残す。
    /// https://docs.joinmastodon.org/methods/statuses/#delete
    public func deleteStatus(_ statusID: Status.ID, deleteMedia: Bool) async throws {
        var url = credential.instance.appending(path: "api/v1/statuses/\(statusID)")
        if deleteMedia {
            url.append(queryItems: [URLQueryItem(name: "delete_media", value: "true")])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    // MARK: - メディアの添付

    /// メディアをアップロードする。小さな画像はその場で変換が済み、`url`の入った添付ファイルが返る。
    /// 動画や大きな画像は変換を待たずに返り、`url`がnilになる。その場合は`waitUntilProcessed`で待つ。
    /// サーバーがファイルを受け付けなければ`MediaUploadError.rejected`、変換に失敗したら`.processingFailed`を投げる。
    /// https://docs.joinmastodon.org/methods/media/#v2
    public func uploadMedia(_ upload: MediaUpload) async throws -> MediaAttachment {
        var form = MultipartFormData()
        form.append(name: "file", filename: upload.filename, mimeType: upload.mimeType, data: upload.data)
        if !upload.description.isEmpty {
            form.append(name: "description", value: upload.description)
        }
        var request = URLRequest(url: credential.instance.appending(path: "api/v2/media"))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        do {
            return try await send(request, decoding: MediaAttachment.self).0
        } catch let error as MastodonAPIError {
            switch error.statusCode {
            case 413, 422: throw MediaUploadError.rejected(error)
            case 500: throw MediaUploadError.processingFailed(error)
            default: throw error
            }
        }
    }

    /// アップロードした添付ファイルの変換の状態。変換に失敗していたら`MediaUploadError.processingFailed`を投げる。
    /// https://docs.joinmastodon.org/methods/media/#get
    public func mediaProcessingState(_ id: String) async throws -> MediaProcessingState {
        let request = URLRequest(url: credential.instance.appending(path: "api/v1/media/\(id)"))
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as MastodonAPIError where error.statusCode == 422 {
            throw MediaUploadError.processingFailed(error)
        }
        // 変換中は206が返る。本文が空のこともあるので読まない。
        guard response.statusCode != 206 else { return .processing }
        let attachment = try decode(MediaAttachment.self, from: data, of: response, for: request)
        return attachment.url == nil ? .processing : .processed(attachment)
    }

    /// 変換が済むまで、状態を問い合わせて待つ。時間で諦めず、止めるのは呼んだタスクのキャンセルだけにする。
    /// 長い動画や混んだサーバーでは変換に数分かかり、待つのをやめてもサーバーは変換を続けるため。
    /// 問い合わせの間隔は、Mastodonのweb UIと同じく、n回目のあとにlog2(n)秒（1秒未満なら1秒）おき、待つほど少しずつ延ばす。
    public func waitUntilProcessed(_ id: String) async throws -> MediaAttachment {
        try await waitUntilProcessed(id, clock: clock)
    }

    func waitUntilProcessed(_ id: String, clock: any Clock<Duration>) async throws -> MediaAttachment {
        var count = 1
        while true {
            if case .processed(let attachment) = try await mediaProcessingState(id) {
                return attachment
            }
            try await clock.sleep(for: .seconds(max(log2(Double(count)), 1)))
            count += 1
        }
    }

    /// 削除した投稿の添付を、新しい投稿に付けられるようになるまで待つ。決まりはdocs/compose.mdの「自分の投稿を削除して書き直す」にある。
    /// サーバーは、削除した投稿を後ろの処理で消し終えるまで添付を投稿に付けたままにし、その間は404を返すので、1秒おきに読み直す。
    /// `timeout`を過ぎても付けられなければ`RedraftMediaError.notReleased`を投げる。通報された投稿は、サーバーが消さずに残すため、いつまでも付けられない。
    public func waitUntilReleased(_ id: String, timeout: Duration = .seconds(60)) async throws -> MediaAttachment {
        try await waitUntilReleased(id, timeout: timeout, clock: clock)
    }

    func waitUntilReleased(_ id: String, timeout: Duration, clock: any Clock<Duration>) async throws -> MediaAttachment {
        let elapsed = stopwatch(on: clock)
        while true {
            do {
                if case .processed(let attachment) = try await mediaProcessingState(id) {
                    return attachment
                }
            } catch let error as MastodonAPIError where error.statusCode == 404 {
                // まだ削除した投稿に付いている。
            }
            guard elapsed() + .seconds(1) <= timeout else { throw RedraftMediaError.notReleased }
            try await clock.sleep(for: .seconds(1))
        }
    }

    /// 代替テキストを送る。空文字列を送ると消える。投稿に付ける前の添付ファイルにだけ使える。
    /// https://docs.joinmastodon.org/methods/media/#update
    public func updateMediaDescription(_ id: String, description: String) async throws -> MediaAttachment {
        try await send(
            formRequest(method: "PUT", path: "api/v1/media/\(id)", form: [URLQueryItem(name: "description", value: description)]),
            decoding: MediaAttachment.self
        ).0
    }

    /// トークンが有効なら返り、無効なら401の`MastodonAPIError`を投げる。
    /// アカウントの他の項目が読めないサーバーでも確かめられるよう、IDだけを読む。
    /// https://docs.joinmastodon.org/methods/accounts/#verify_credentials
    public func verifyCredentials() async throws {
        struct Verified: Decodable {
            let id: String
        }
        _ = try await get(Verified.self, path: "api/v1/accounts/verify_credentials", query: [])
    }

    // MARK: - プロフィールの編集

    /// 自分のプロフィールを、編集できる平文と一緒に読む。
    /// https://docs.joinmastodon.org/methods/accounts/#verify_credentials
    public func profileSource() async throws -> ProfileSource {
        try await get(ProfileSource.self, path: "api/v1/accounts/verify_credentials", query: []).0
    }

    /// プロフィールを保存し、保存したあとのプロフィールを返す。画像を消すときは、ほかの項目を保存してから消す。
    /// 消すのは別のAPIで、保存と1度には送れないため。
    /// https://docs.joinmastodon.org/methods/accounts/#update_credentials
    public func updateProfile(_ draft: ProfileDraft) async throws -> ProfileSource {
        var form = MultipartFormData()
        form.append(name: "display_name", value: draft.displayName)
        form.append(name: "note", value: draft.note)
        form.append(name: "locked", value: draft.locked ? "true" : "false")
        form.append(name: "bot", value: draft.bot ? "true" : "false")
        // 補足情報は送った並びで置き換わる。送らないと変わらないので、全部消すときは空の行を1つ送る。空の行はサーバーが捨てる。
        let fields = draft.sentFields.isEmpty ? [ProfileSource.Field(name: "", value: "")] : draft.sentFields
        for (index, field) in fields.enumerated() {
            form.append(name: "fields_attributes[\(index)][name]", value: field.name)
            form.append(name: "fields_attributes[\(index)][value]", value: field.value)
        }
        for (name, change) in [("avatar", draft.avatar), ("header", draft.header)] {
            guard case .replace(let upload) = change else { continue }
            form.append(name: name, filename: upload.filename, mimeType: upload.mimeType, data: upload.data)
        }
        var request = URLRequest(url: credential.instance.appending(path: "api/v1/accounts/update_credentials"))
        request.httpMethod = "PATCH"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        var saved = try await send(request, decoding: ProfileSource.self).0
        for (image, change) in [(ProfileImage.avatar, draft.avatar), (.header, draft.header)] where change == .remove {
            saved = try await deleteProfileImage(image)
        }
        return saved
    }

    /// https://docs.joinmastodon.org/methods/profile/#delete-profile-avatar
    /// https://docs.joinmastodon.org/methods/profile/#delete-profile-header
    private func deleteProfileImage(_ image: ProfileImage) async throws -> ProfileSource {
        var request = URLRequest(url: credential.instance.appending(path: "api/v1/profile/\(image.rawValue)"))
        request.httpMethod = "DELETE"
        return try await send(request, decoding: ProfileSource.self).0
    }

    /// 一度に読めるアカウントの数。Mastodonは、これより多く求めると422を返す（`Api::BaseController::DEFAULT_ACCOUNTS_LIMIT`）。
    public static let multipleAccountsLimit = 40

    /// アカウントをまとめて読む。見つからないアカウントと、承認されていないアカウントは返らない。
    /// メニューを開いたときに使い、メニューを閉じれば要らなくなるため、一時的な失敗でも送り直さない。
    /// https://docs.joinmastodon.org/methods/accounts/#index
    public func accounts(_ ids: [String]) async throws -> [Account] {
        let query = ids.map { URLQueryItem(name: "id[]", value: $0) }
        return try await get(ElementList<Account>.self, path: "api/v1/accounts", query: query, feature: .multipleAccounts, retries: false).0.elements
    }

    /// https://docs.joinmastodon.org/methods/accounts/#get
    public func account(_ id: String) async throws -> Account {
        try await get(Account.self, path: "api/v1/accounts/\(id)", query: []).0
    }

    /// 自分と相手の関係。相手が見つからなければnil。
    /// https://docs.joinmastodon.org/methods/accounts/#relationships
    public func relationship(with id: String) async throws -> Relationship? {
        try await relationships([id]).first { $0.id == id }
    }

    /// 一度に読む関係の数。Mastodonはこのエンドポイントで数を制限しないが、URLが長くなりすぎないよう、アカウントのまとめ読みと同じ数で区切る。
    public static let multipleRelationshipsLimit = multipleAccountsLimit

    /// 自分と相手たちの関係をまとめて読む。見つからない相手の関係は返らない。
    /// https://docs.joinmastodon.org/methods/accounts/#relationships
    public func relationships(_ ids: [String]) async throws -> [Relationship] {
        let query = ids.map { URLQueryItem(name: "id[]", value: $0) }
        return try await get([Relationship].self, path: "api/v1/accounts/relationships", query: query).0
    }

    /// アカウントの投稿を新しい順に返す。
    /// https://docs.joinmastodon.org/methods/accounts/#statuses
    public func accountStatuses(_ id: String, filter: AccountStatusFilter, query: TimelineQuery) async throws -> TimelinePage {
        let list = try await get(ElementList<Status>.self, path: "api/v1/accounts/\(id)/statuses", query: filter.queryItems + query.queryItems).0
        return TimelinePage(statuses: list.elements, unreadable: list.unreadable, isRegenerating: false)
    }

    /// 自分のリストをすべて返す。ページに分けずに返る。
    /// https://docs.joinmastodon.org/methods/lists/#get
    public func lists() async throws -> [MastodonList] {
        try await get([MastodonList].self, path: "api/v1/lists", query: []).0
    }

    /// リストを作る。数と名前の長さの上限はAPIで返らないので、手元では止めない。超えたら、サーバーが422で断る。
    /// https://docs.joinmastodon.org/methods/lists/#create
    public func createList(title: String) async throws -> MastodonList {
        try await post(MastodonList.self, path: "api/v1/lists", form: [URLQueryItem(name: "title", value: title)]).0
    }

    /// リストの名前と設定を変える。サーバーは`title`を毎回求めるので、名前を変えないときも今の名前を渡す。nilの設定は送らず、今のままにする。
    /// https://docs.joinmastodon.org/methods/lists/#update
    public func updateList(_ listID: String, title: String, repliesPolicy: ListRepliesPolicy? = nil, exclusive: Bool? = nil) async throws -> MastodonList {
        var form = [URLQueryItem(name: "title", value: title)]
        if let repliesPolicy {
            form.append(URLQueryItem(name: "replies_policy", value: repliesPolicy.rawValue))
        }
        if let exclusive {
            form.append(URLQueryItem(name: "exclusive", value: exclusive ? "true" : "false"))
        }
        return try await send(formRequest(method: "PUT", path: "api/v1/lists/\(listID)", form: form), decoding: MastodonList.self).0
    }

    /// リストを消す。
    /// https://docs.joinmastodon.org/methods/lists/#delete
    public func deleteList(_ listID: String) async throws {
        var request = URLRequest(url: credential.instance.appending(path: "api/v1/lists/\(listID)"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// リストに人を足す。Mastodonが足せるのは、フォロー中かフォローをリクエスト中の人と、自分だけ。ほかの人なら404、もう入っていれば422で断る。
    /// https://docs.joinmastodon.org/methods/lists/#accounts-add
    public func addAccounts(_ accountIDs: [String], toList listID: String) async throws {
        let form = accountIDs.map { URLQueryItem(name: "account_ids[]", value: $0) }
        _ = try await send(formRequest(method: "POST", path: "api/v1/lists/\(listID)/accounts", form: form))
    }

    /// リストから人を外す。入っていない人を外しても成功する。
    /// https://docs.joinmastodon.org/methods/lists/#accounts-remove
    public func removeAccounts(_ accountIDs: [String], fromList listID: String) async throws {
        let form = accountIDs.map { URLQueryItem(name: "account_ids[]", value: $0) }
        _ = try await send(formRequest(method: "DELETE", path: "api/v1/lists/\(listID)/accounts", form: form))
    }

    /// 自分のリストのうち、その人が入っているもの。ページに分けずに返る。
    /// https://docs.joinmastodon.org/methods/accounts/#lists
    public func lists(containing accountID: String) async throws -> [MastodonList] {
        try await get([MastodonList].self, path: "api/v1/accounts/\(accountID)/lists", query: []).0
    }

    /// リストのタイムラインを新しい順に返す。
    /// https://docs.joinmastodon.org/methods/timelines/#list
    public func listTimeline(_ listID: String, _ query: TimelineQuery) async throws -> TimelinePage {
        let list = try await get(ElementList<Status>.self, path: "api/v1/timelines/list/\(listID)", query: query.queryItems).0
        return TimelinePage(statuses: list.elements, unreadable: list.unreadable, isRegenerating: false)
    }

    /// ハッシュタグをフォローする。フォロー済みでも成功する。
    /// https://docs.joinmastodon.org/methods/tags/#follow
    public func followTag(_ name: String) async throws {
        _ = try await post(Hashtag.self, url: tagURL("api/v1/tags", name, "follow"), form: [])
    }

    /// ハッシュタグのフォローを外す。フォローしていなくても成功する。
    /// https://docs.joinmastodon.org/methods/tags/#unfollow
    public func unfollowTag(_ name: String) async throws {
        _ = try await post(Hashtag.self, url: tagURL("api/v1/tags", name, "unfollow"), form: [])
    }

    /// ハッシュタグのタイムラインを新しい順に返す。`name`は`#`を除いた名前。
    /// https://docs.joinmastodon.org/methods/timelines/#tag
    public func hashtagTimeline(_ name: String, _ query: TimelineQuery) async throws -> TimelinePage {
        let list = try await get(ElementList<Status>.self, url: tagURL("api/v1/timelines/tag", name), query: query.queryItems).0
        return TimelinePage(statuses: list.elements, unreadable: list.unreadable, isRegenerating: false)
    }

    /// 自分のサーバーのハッシュタグのページ（`https://<サーバー>/tags/<名前>`）。`Tag.url`と同じ形。名前はAPIのURLと同じく、1つの区切りとして符号化して足す。
    public func tagPageURL(_ name: String) -> URL {
        tagURL("tags", name)
    }

    /// ハッシュタグのAPIのURL。名前は本文のリンクの文字列から取ることがあり、`/`や`..`を含みうるため、1つの区切りとして符号化して足す。
    /// パスの文字列に埋めると、`../`がそのまま残り、自分のサーバーのほかのAPIへトークンを付けて送ってしまう。
    private func tagURL(_ prefix: String, _ name: String, _ suffix: String? = nil) -> URL {
        let url = credential.instance.appending(path: prefix).appending(component: name)
        return suffix.map { url.appending(path: $0) } ?? url
    }

    /// フォローしているハッシュタグをすべて返す。続きを`Link`ヘッダーで読み、最後まで読み切ってから返す。途中で読めなければ投げる。
    /// 読めない要素を捨てずに投げるのは、欠けた一覧で並びを書き換えると、読めなかったハッシュタグを並びから外してしまうため。
    /// 1回に読める件数の上限は200件。
    /// https://docs.joinmastodon.org/methods/followed_tags/#get
    public func followedTags() async throws -> [Hashtag] {
        try await allPages(path: "api/v1/followed_tags", limit: 200) { path, query in
            try await get([Hashtag].self, path: path, query: query)
        }
    }

    /// ブックマークした投稿を、ブックマークした新しい順に返す。1回に読める件数の上限は40件。
    /// - Parameter maxID: 前のページの`SavedStatusesPage.nextMaxID`。nilなら最新のページ。
    /// https://docs.joinmastodon.org/methods/bookmarks/#get
    public func bookmarks(maxID: String?, limit: Int) async throws -> SavedStatusesPage {
        try await savedStatuses(path: "api/v1/bookmarks", maxID: maxID, limit: limit)
    }

    /// お気に入りした投稿を、お気に入りした新しい順に返す。1回に読める件数の上限は40件。
    /// - Parameter maxID: 前のページの`SavedStatusesPage.nextMaxID`。nilなら最新のページ。
    /// https://docs.joinmastodon.org/methods/favourites/#get
    public func favourites(maxID: String?, limit: Int) async throws -> SavedStatusesPage {
        try await savedStatuses(path: "api/v1/favourites", maxID: maxID, limit: limit)
    }

    /// 人の一覧を、サーバーが返す順に返す。1回に読める件数の上限は80件。
    /// - Parameter maxID: 前のページの`AccountListPage.nextMaxID`。nilなら最初のページ。
    /// https://docs.joinmastodon.org/methods/statuses/#favourited_by
    /// https://docs.joinmastodon.org/methods/statuses/#reblogged_by
    /// https://docs.joinmastodon.org/methods/accounts/#followers
    /// https://docs.joinmastodon.org/methods/accounts/#following
    /// https://docs.joinmastodon.org/methods/lists/#accounts
    /// https://docs.joinmastodon.org/methods/accounts/#endorsements
    public func accounts(in list: AccountListKind, maxID: String?, limit: Int) async throws -> AccountListPage {
        if case .emojiReactionedBy(let statusID, let name) = list {
            return try await emojiReactionedBy(statusID, name: name, maxID: maxID, limit: limit)
        }
        let path = switch list {
        case .emojiReactionedBy: preconditionFailure("上で返している")
        case .favouritedBy(let statusID): "api/v1/statuses/\(statusID)/favourited_by"
        case .rebloggedBy(let statusID): "api/v1/statuses/\(statusID)/reblogged_by"
        case .followers(let accountID): "api/v1/accounts/\(accountID)/followers"
        case .following(let accountID): "api/v1/accounts/\(accountID)/following"
        case .listMembers(let listID): "api/v1/lists/\(listID)/accounts"
        case .endorsements(let accountID): "api/v1/accounts/\(accountID)/endorsements"
        }
        let query = [URLQueryItem(name: "limit", value: String(limit))] + (maxID.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
        let (accounts, response) = try await get(ElementList<Account>.self, path: path, query: query)
        let link = response.value(forHTTPHeaderField: "Link").map(LinkHeader.init)
        return AccountListPage(accounts: accounts.elements, nextMaxID: link?.queryValue("max_id", of: "next"))
    }

    /// 投稿にその絵文字でリアクションした人。Fedibirdの`emoji_reactioned_by`は絵文字で絞れず、どの絵文字のリアクションも、人と絵文字の組でページに分けて返すので、
    /// `name`のものだけを手元で絞る。同じ絵文字かは、ほかと同じく名前だけで見分ける（docs/emoji-reaction.mdの「リアクションした人」）。
    /// 絞ったページに人がいなければ、合う人が見つかるか最後のページに着くまで、続けて読む。人の一覧は、最初のページが空なら続きを読まないため。
    private func emojiReactionedBy(_ statusID: Status.ID, name: String, maxID: String?, limit: Int) async throws -> AccountListPage {
        struct Reacted: Decodable {
            let name: String
            let account: Account
        }
        var maxID = maxID
        var readMaxIDs: Set<String> = []
        while true {
            let query = [URLQueryItem(name: "limit", value: String(limit))] + (maxID.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
            let (reactions, response) = try await get(ElementList<Reacted>.self, path: "api/v1/statuses/\(statusID)/emoji_reactioned_by", query: query)
            let link = response.value(forHTTPHeaderField: "Link").map(LinkHeader.init)?.queryValue("max_id", of: "next")
            // `allPages`と同じく、読んだ位置を返すサーバー（同じ位置を返し続ける、位置が循環する）で、同じページを読み続けないよう止める。
            if let maxID { readMaxIDs.insert(maxID) }
            let next = link.flatMap { readMaxIDs.contains($0) || reactions.elements.isEmpty ? nil : $0 }
            let accounts = reactions.elements.filter { $0.name == name }.map(\.account)
            guard accounts.isEmpty, let next else {
                return AccountListPage(accounts: accounts, nextMaxID: next)
            }
            maxID = next
        }
    }

    /// `max_id`は投稿のIDではない内部のIDで、`Link`ヘッダーの`next`のURLにだけ書かれている。
    /// URLをそのまま開かず`max_id`だけを取り出すのは、トークンを付けて送る先を、ログインしたサーバーの決まったパスに限るため。
    private func savedStatuses(path: String, maxID: String?, limit: Int) async throws -> SavedStatusesPage {
        let query = [URLQueryItem(name: "limit", value: String(limit))] + (maxID.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
        let (list, response) = try await get(ElementList<Status>.self, path: path, query: query)
        let link = response.value(forHTTPHeaderField: "Link").map(LinkHeader.init)
        return SavedStatusesPage(statuses: list.elements, unreadable: list.unreadable, nextMaxID: link?.queryValue("max_id", of: "next"))
    }

    /// プロフィールのURLからアカウントを探す。自分のサーバーが知らないアカウントも、相手のサーバーに問い合わせて探す。見つからなければnil。
    /// Mastodonは、検索の語がスキームの小文字の`http://`か`https://`で始まるときだけURLとして問い合わせ、ほかは文字列で検索するため、スキームを小文字にして送る。
    public func resolveAccount(at url: URL) async throws -> Account? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = url.scheme?.lowercased()
        return try await resolveAccount(components?.string ?? url.absoluteString)
    }

    /// `user@domain`の形のacctか、プロフィールのURLからアカウントを探す。自分のサーバーが知らないアカウントも、相手のサーバーに問い合わせて探す。
    /// 見つからなければnil。
    /// https://docs.joinmastodon.org/methods/search/#v2
    public func resolveAccount(_ acct: String) async throws -> Account? {
        struct Results: Decodable {
            let accounts: [Account]
        }
        let query = [
            URLQueryItem(name: "q", value: acct),
            URLQueryItem(name: "type", value: "accounts"),
            URLQueryItem(name: "resolve", value: "true"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return try await get(Results.self, path: "api/v2/search", query: query).0.accounts.first
    }

    /// 投稿欄のメンションの補完に使う。web UIと同じく、打つたびに相手のサーバーへ問い合わせると遅いので、自分のサーバーが知っているアカウントだけを探す。
    /// `api/v2/search`の`type=accounts`もサーバーの中では同じ検索をするが、アカウントだけを返す専用の口で、web UIの補完と同じこちらを使う。
    /// 打っている途中の問い合わせなので、一時的な失敗でも送り直さない。待つより、次に打った文字で問い合わせ直すほうが早い。
    /// https://docs.joinmastodon.org/methods/accounts/#search
    /// - Parameter following: フォローしている人だけから探す。
    public func searchAccountsForCompletion(_ query: String, limit: Int, following: Bool = false) async throws -> [Account] {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "resolve", value: "false"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if following {
            items.append(URLQueryItem(name: "following", value: "true"))
        }
        return try await get(ElementList<Account>.self, path: "api/v1/accounts/search", query: items, retries: false).0.elements
    }

    /// リストのメンバーの画面で、足す人を探す。リストに足せるのはフォローしている人だけなので、フォローしている人に絞る。
    /// 補完と同じく、打っている途中の問い合わせなので、相手のサーバーには問い合わせず、一時的な失敗でも送り直さない。
    /// https://docs.joinmastodon.org/methods/accounts/#search
    public func searchFollowedAccounts(_ query: String, limit: Int) async throws -> [Account] {
        let items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "resolve", value: "false"),
            URLQueryItem(name: "following", value: "true"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        return try await get(ElementList<Account>.self, path: "api/v1/accounts/search", query: items, retries: false).0.elements
    }

    /// 投稿欄のハッシュタグの補完に使う。web UIは`exclude_unreviewed`を付けるが、管理者が確かめていないタグ（小さなサーバーではほとんど）が出なくなるため付けない。
    /// メンションと同じく、一時的な失敗でも送り直さない。
    /// https://docs.joinmastodon.org/methods/search/#v2
    public func searchHashtagsForCompletion(_ query: String, limit: Int) async throws -> [Hashtag] {
        struct Results: Decodable {
            let hashtags: ElementList<Hashtag>
        }
        let items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "hashtags"),
            URLQueryItem(name: "resolve", value: "false"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        return try await get(Results.self, path: "api/v2/search", query: items, retries: false).0.hashtags.elements
    }

    /// 検索の画面で探す。決まりはdocs/search.mdにある。
    /// - Parameter category: 探す種類。nilなら3つをまとめて探す。まとめて探すと、サーバーは`offset`を無視する。
    /// - Parameter resolve: 自分のサーバーが知らないユーザーや、URLの投稿とプロフィールを、相手のサーバーに問い合わせて探す。
    /// - Parameter offset: 先頭から飛ばす件数。サーバーはミュートやブロックした人の投稿を除く前の件数で数えるため、読めた件数ではなく、頼んだ件数を足して進める。
    /// https://docs.joinmastodon.org/methods/search/#v2
    public func search(_ query: String, category: SearchCategory?, resolve: Bool, limit: Int, offset: Int = 0) async throws -> SearchResults {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "resolve", value: resolve ? "true" : "false"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let category {
            items.append(URLQueryItem(name: "type", value: category.rawValue))
            if offset > 0 {
                items.append(URLQueryItem(name: "offset", value: "\(offset)"))
            }
        }
        return try await get(SearchResults.self, path: "api/v2/search", query: items).0
    }

    /// プロフィールに載せているハッシュタグ。補完で、自分のタグとして先に出す。
    /// https://docs.joinmastodon.org/methods/featured_tags/#get
    public func featuredTags() async throws -> [FeaturedTag] {
        try await get(ElementList<FeaturedTag>.self, path: "api/v1/featured_tags", query: []).0.elements
    }

    /// アカウントがプロフィールに載せているハッシュタグ。サーバーが返した順。
    /// https://docs.joinmastodon.org/methods/accounts/#featured_tags
    public func featuredTags(of accountID: String) async throws -> [FeaturedTag] {
        try await get(ElementList<FeaturedTag>.self, path: "api/v1/accounts/\(accountID)/featured_tags", query: []).0.elements
    }

    /// ハッシュタグを自分のプロフィールに載せる。上限を超えたときや、載せているタグをもう一度載せたときは、サーバーが422を返す。
    /// 二重に載せようとして断られないよう、一時的な失敗でも送り直さない。
    /// https://docs.joinmastodon.org/methods/featured_tags/#feature
    public func featureTag(_ name: String) async throws -> FeaturedTag {
        try await send(formRequest(method: "POST", path: "api/v1/featured_tags", form: [URLQueryItem(name: "name", value: name)]), decoding: FeaturedTag.self, retries: false).0
    }

    /// ハッシュタグを自分のプロフィールから外す。`id`は`FeaturedTag`のID。外したものをもう一度外すと、サーバーは404を返す。
    /// https://docs.joinmastodon.org/methods/featured_tags/#unfeature
    public func unfeatureTag(_ id: String) async throws {
        var request = URLRequest(url: credential.instance.appending(path: "api/v1/featured_tags/\(id)"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// 自分のプロフィールで紹介しているアカウントをすべて返す。続きを`Link`ヘッダーで読み、最後まで読み切ってから返す。途中で読めなければ投げる。
    /// 1回に読める件数の上限は80件。
    /// https://docs.joinmastodon.org/methods/endorsements/#get
    public func endorsements() async throws -> [Account] {
        try await allPages(path: "api/v1/endorsements", limit: 80) { path, query in
            let (page, response) = try await get(ElementList<Account>.self, path: path, query: query)
            return (page.elements, response)
        }
    }

    /// 相手を自分のプロフィールで紹介する。フォローしていない相手は、サーバーが422で断る。
    /// Mastodon 4.4で`endorse`に名前が変わったが、`pin`は同じ処理の別名として残っていて、4.4より前のサーバーにもあるため、こちらで送る。
    /// https://docs.joinmastodon.org/methods/accounts/#pin
    public func endorse(_ id: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/pin", form: []).0
    }

    /// 相手をプロフィールの紹介から外す。`endorse`と同じく、どの版にもある古い名前で送る。
    /// https://docs.joinmastodon.org/methods/accounts/#unpin
    public func unendorse(_ id: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/unpin", form: []).0
    }

    /// 最近使ったハッシュタグ（最大10件）。補完で、自分のタグとして先に出す。
    /// サーバーは直近1年の最新1000投稿で2回以上使ったタグから、プロフィールに載せているものを除いて返す。
    /// https://docs.joinmastodon.org/methods/featured_tags/#suggestions
    public func featuredTagSuggestions() async throws -> [Hashtag] {
        try await get(ElementList<Hashtag>.self, path: "api/v1/featured_tags/suggestions", query: []).0.elements
    }

    /// 自分の最近の投稿に付いていたタグを、新しい投稿のものから返す。補完で、自分のタグとして先に出す。
    /// `featuredTagSuggestions`は2回以上使ったタグしか返さないので、1回だけ使ったタグはここで拾う。
    /// ブーストに付いたタグは自分が付けたものではないので除く。40件はこのAPIの上限。
    /// https://docs.joinmastodon.org/methods/accounts/#statuses
    public func recentStatusTags(of accountID: String) async throws -> [Hashtag] {
        let page = try await accountStatuses(accountID, filter: AccountStatusFilter(excludesReblogs: true), query: TimelineQuery(limit: 40))
        return Hashtag.used(in: page.statuses)
    }

    /// サーバーで使えるカスタム絵文字の一覧。補完ではまとめて一度だけ取り、手元で絞る。
    /// 同じショートコードの絵文字は、後に来た1件だけを残す（`ServerEmoji.lastOfEachShortcode`）。
    /// https://docs.joinmastodon.org/methods/custom_emojis/
    public func customEmojis() async throws -> [ServerEmoji] {
        let emojis = try await get(ElementList<ServerEmoji>.self, path: "api/v1/custom_emojis", query: []).0.elements
        return ServerEmoji.lastOfEachShortcode(emojis)
    }

    // MARK: - お知らせ

    /// サーバーが出しているお知らせを、既読にしたものも含めてすべて返す。ページに分けずに返る。
    /// https://docs.joinmastodon.org/methods/announcements/#get
    public func announcements() async throws -> AnnouncementList {
        let list = try await get(ElementList<Announcement>.self, path: "api/v1/announcements", query: []).0
        return AnnouncementList(announcements: list.elements, unreadable: list.unreadable)
    }

    /// お知らせを既読にする。応答の中身は使わない。
    /// https://docs.joinmastodon.org/methods/announcements/#dismiss
    public func dismissAnnouncement(_ id: Announcement.ID) async throws {
        _ = try await send(formRequest(method: "POST", path: "api/v1/announcements/\(id)/dismiss", form: []))
    }

    /// お知らせにリアクションする。`name`はUnicodeの絵文字か、カスタム絵文字のショートコード。
    /// 同じリアクションをもう一度送ると、サーバーは重複として断る。
    /// https://docs.joinmastodon.org/methods/announcements/#put-reactions
    public func addAnnouncementReaction(_ id: Announcement.ID, name: String) async throws {
        _ = try await send(formRequest(method: "PUT", url: announcementReactionURL(id, name: name), form: []))
    }

    /// お知らせにした自分のリアクションを外す。
    /// https://docs.joinmastodon.org/methods/announcements/#delete-reactions
    public func removeAnnouncementReaction(_ id: Announcement.ID, name: String) async throws {
        var request = URLRequest(url: announcementReactionURL(id, name: name))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// 絵文字は1つのパスの要素としてエンコードする。キーキャップの`#️⃣`のように、URLで意味を持つ文字を含む絵文字があるため。
    private func announcementReactionURL(_ id: Announcement.ID, name: String) -> URL {
        credential.instance.appending(path: "api/v1/announcements/\(id)/reactions").appending(component: name)
    }

    /// 投稿に絵文字でリアクションする。Fedibirdの拡張で、`fedibird_capabilities`に`emoji_reaction`があるサーバーでだけ使う。
    /// Fedibirdは、付けられなかったときも投稿を返すので、返った投稿に自分のリアクションがあるかで確かめる。
    /// fedibird/mastodonの`app/controllers/api/v1/statuses/emoji_reactions_controller.rb`
    public func addEmojiReaction(_ statusID: Status.ID, emoji: ReactionEmoji) async throws -> Status {
        try await send(formRequest(method: "PUT", url: emojiReactionURL(statusID, emoji: emoji), form: []), decoding: Status.self).0
    }

    /// 投稿にした自分の絵文字のリアクションを外す。
    public func removeEmojiReaction(_ statusID: Status.ID, emoji: ReactionEmoji) async throws -> Status {
        var request = URLRequest(url: emojiReactionURL(statusID, emoji: emoji))
        request.httpMethod = "DELETE"
        return try await send(request, decoding: Status.self).0
    }

    /// 絵文字は1つのパスの要素としてエンコードする。お知らせのリアクションと同じ理由。
    private func emojiReactionURL(_ statusID: Status.ID, emoji: ReactionEmoji) -> URL {
        credential.instance.appending(path: "api/v1/statuses/\(statusID)/emoji_reactions").appending(component: emoji.requestName)
    }

    /// 鍵のかかったアカウントには、フォローのリクエストを送る。
    /// フォローしている相手にもう一度送ると、ブーストを流すかと投稿の通知の設定だけを変えられる。nilの設定は送らず、サーバーの既定（新しいフォローなら流す・通知しない、フォロー済みなら今のまま）に任せる。
    /// https://docs.joinmastodon.org/methods/accounts/#follow
    public func follow(_ id: String, reblogs: Bool? = nil, notify: Bool? = nil) async throws -> Relationship {
        var form: [URLQueryItem] = []
        if let reblogs { form.append(URLQueryItem(name: "reblogs", value: reblogs ? "true" : "false")) }
        if let notify { form.append(URLQueryItem(name: "notify", value: notify ? "true" : "false")) }
        return try await post(Relationship.self, path: "api/v1/accounts/\(id)/follow", form: form).0
    }

    /// フォローを外す。承認を待っているリクエストも取り消す。
    /// https://docs.joinmastodon.org/methods/accounts/#unfollow
    public func unfollow(_ id: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/unfollow", form: []).0
    }

    /// 相手の投稿と、相手からの通知を隠す。通知を隠すかの`notifications`はサーバーの既定（隠す）に任せる。
    /// - Parameter duration: ミュートを続ける時間。nilなら解除するまで続ける。
    /// https://docs.joinmastodon.org/methods/accounts/#mute
    public func mute(_ id: String, duration: Duration?) async throws -> Relationship {
        let form = duration.map { [URLQueryItem(name: "duration", value: "\($0.components.seconds)")] } ?? []
        return try await post(Relationship.self, path: "api/v1/accounts/\(id)/mute", form: form).0
    }

    /// 相手のプロフィールに、自分にしか見えないメモを書く。空なら消す。
    /// https://docs.joinmastodon.org/methods/accounts/#note
    public func setNote(_ id: String, comment: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/note", form: [URLQueryItem(name: "comment", value: comment)]).0
    }

    /// 自分のフィルターをすべて返す。ページに分けずに返る。
    /// https://docs.joinmastodon.org/methods/filters/#get
    public func filters() async throws -> [ServerFilter] {
        try await get([ServerFilter].self, path: "api/v2/filters", query: []).0
    }

    /// フィルターを作る。
    /// - Parameter expiresIn: 期限までの時間。nilなら期限を付けない。
    /// https://docs.joinmastodon.org/methods/filters/#create
    public func createFilter(title: String, context: [FilterResult.Context], action: FilterResult.Action, expiresIn: Duration?, keywords: [ServerFilter.KeywordDraft]) async throws -> ServerFilter {
        var form = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "filter_action", value: action.rawValue)]
        form += context.map { URLQueryItem(name: "context[]", value: $0.rawValue) }
        if let expiresIn {
            form.append(URLQueryItem(name: "expires_in", value: "\(expiresIn.components.seconds)"))
        }
        for keyword in keywords {
            form.append(URLQueryItem(name: "keywords_attributes[][keyword]", value: keyword.keyword))
            form.append(URLQueryItem(name: "keywords_attributes[][whole_word]", value: keyword.wholeWord ? "true" : "false"))
        }
        return try await post(ServerFilter.self, path: "api/v2/filters", form: form).0
    }

    /// フィルターを消す。
    /// https://docs.joinmastodon.org/methods/filters/#delete
    public func deleteFilter(_ id: String) async throws {
        var request = URLRequest(url: credential.instance.appending(path: "api/v2/filters/\(id)"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// フィルターのキーワードを1つ消す。フィルターのほかのキーワードは残る。
    /// https://docs.joinmastodon.org/methods/filters/#keywords-delete
    public func deleteFilterKeyword(_ id: String) async throws {
        var request = URLRequest(url: credential.instance.appending(path: "api/v2/filters/keywords/\(id)"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// https://docs.joinmastodon.org/methods/accounts/#unmute
    public func unmute(_ id: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/unmute", form: []).0
    }

    /// ブロックすると、サーバーはお互いのフォローを外す。
    /// https://docs.joinmastodon.org/methods/accounts/#block
    public func block(_ id: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/block", form: []).0
    }

    /// https://docs.joinmastodon.org/methods/accounts/#unblock
    public func unblock(_ id: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/accounts/\(id)/unblock", form: []).0
    }

    /// ユーザーのメニューの関係の項目で選んだ変更を、相手`id`へ送る。
    public func send(_ change: UserRelationChange, to id: String) async throws -> Relationship {
        switch change {
        case .follow: try await follow(id)
        case .unfollow, .cancelFollowRequest: try await unfollow(id)
        case .showReblogs(let shows): try await follow(id, reblogs: shows)
        case .notify(let notifies): try await follow(id, notify: notifies)
        case .endorse(true): try await endorse(id)
        case .endorse(false): try await unendorse(id)
        case .mute(let duration): try await mute(id, duration: duration)
        case .unmute: try await unmute(id)
        case .block: try await block(id)
        case .unblock: try await unblock(id)
        }
    }

    /// アカウントを通報する。応答の中身は使わない。`Idempotency-Key`を受け付けないため、二重に届かないよう送り直さない。
    /// https://docs.joinmastodon.org/methods/reports/#post
    public func report(_ request: ReportRequest) async throws {
        var form = [
            URLQueryItem(name: "account_id", value: request.accountID),
            URLQueryItem(name: "comment", value: request.comment),
            URLQueryItem(name: "forward", value: request.forward ? "true" : "false"),
            URLQueryItem(name: "category", value: request.category.rawValue),
        ]
        form += request.statusIDs.map { URLQueryItem(name: "status_ids[]", value: $0) }
        if request.category == .violation {
            form += request.ruleIDs.map { URLQueryItem(name: "rule_ids[]", value: $0) }
        }
        _ = try await send(formRequest(method: "POST", path: "api/v1/reports", form: form))
    }

    /// サーバーのルール。通報でルールへの違反を選ぶときに出す。
    /// https://docs.joinmastodon.org/methods/instance/#rules
    public func instanceRules() async throws -> [InstanceRule] {
        try await get(ElementList<InstanceRule>.self, path: "api/v1/instance/rules", query: []).0.elements
    }

    /// 通知のまとまりを削除する。まとめない通知は、`ungrouped-<通知のID>`のキーで1件だけ消える。応答の中身は使わない。
    /// v2のないサーバーでは、通知をまとめずに読んでいるので、キーの通知のIDをv1で消す。
    /// v2の削除のパスはキーを含み、404はまとまりがないことも表すため、v2がないことはここでは判断せず、読み込みで分かったものを使う。
    /// https://docs.joinmastodon.org/methods/grouped_notifications/#dismiss-group
    /// https://docs.joinmastodon.org/methods/notifications/#dismiss
    public func dismissNotificationGroup(_ groupKey: String) async throws {
        if await features.isDisabled(.groupedNotifications), let id = MastodonNotification.ungroupedID(of: groupKey) {
            let key = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
            _ = try await send(formRequest(method: "POST", path: "api/v1/notifications/\(key)/dismiss", form: []))
            return
        }
        let key = groupKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? groupKey
        _ = try await send(formRequest(method: "POST", path: "api/v2/notifications/\(key)/dismiss", form: []))
    }

    /// 自分へのフォローリクエストを承認する。サーバーはリクエストの通知を消し、代わりにフォローの通知を作る。
    /// 承認を待っているリクエストがなければ404を返す。
    /// https://docs.joinmastodon.org/methods/follow_requests/#accept
    public func authorizeFollowRequest(from accountID: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/follow_requests/\(accountID)/authorize", form: []).0
    }

    /// 自分へのフォローリクエストを却下する。サーバーはリクエストの通知を消す。
    /// 承認を待っているリクエストがなければ404を返す。
    /// https://docs.joinmastodon.org/methods/follow_requests/#reject
    public func rejectFollowRequest(from accountID: String) async throws -> Relationship {
        try await post(Relationship.self, path: "api/v1/follow_requests/\(accountID)/reject", form: []).0
    }

    /// - Parameter feature: なくても使える機能のAPIなら、その機能。使えないと分かったら、セッションの間は送らない。
    /// - Parameter retries: 一時的な失敗で送り直すか。
    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem], feature: OptionalFeature? = nil, retries: Bool = true) async throws -> (T, HTTPURLResponse) {
        try await get(type, url: credential.instance.appending(path: path), query: query, feature: feature, retries: retries)
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL, query: [URLQueryItem], feature: OptionalFeature? = nil, retries: Bool = true) async throws -> (T, HTTPURLResponse) {
        try await send(URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query)), decoding: type, feature: feature, retries: retries)
    }

    private func post<T: Decodable>(
        _ type: T.Type,
        path: String,
        form: [URLQueryItem],
        headers: [String: String] = [:],
        feature: OptionalFeature? = nil
    ) async throws -> (T, HTTPURLResponse) {
        try await post(type, url: credential.instance.appending(path: path), form: form, headers: headers, feature: feature)
    }

    private func post<T: Decodable>(
        _ type: T.Type,
        url: URL,
        form: [URLQueryItem],
        headers: [String: String] = [:],
        feature: OptionalFeature? = nil
    ) async throws -> (T, HTTPURLResponse) {
        try await send(formRequest(method: "POST", url: url, form: form, headers: headers), decoding: type, feature: feature)
    }

    private func formRequest(method: String, path: String, form: [URLQueryItem], headers: [String: String] = [:]) -> URLRequest {
        formRequest(method: method, url: credential.instance.appending(path: path), form: form, headers: headers)
    }

    private func formRequest(method: String, url: URL, form: [URLQueryItem], headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form
        // URLComponentsは`+`をエンコードしないが、form-urlencodedでは`+`が空白として読まれるため、エンコードしておく。
        let body = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        request.httpBody = Data(body.utf8)
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decoding type: T.Type, feature: OptionalFeature? = nil, retries: Bool = true) async throws -> (T, HTTPURLResponse) {
        let (data, response) = try await send(request, feature: feature, retries: retries)
        return (try decode(type, from: data, of: response, for: request), response)
    }

    /// 読めなければ、どの項目が読めなかったかを記録して投げる。
    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        of response: HTTPURLResponse,
        for request: URLRequest,
        using decoder: JSONDecoder = MastodonDecoder.make()
    ) throws -> T {
        do {
            let context = DecodingLog.Context(request: "\(request.httpMethod ?? "GET") \(request.url.map(RequestLog.redactedPath) ?? "")", data: data)
            return try DecodingLog.$context.withValue(context) {
                try decoder.decode(type, from: data)
            }
        } catch {
            requestLog.record(request, statusCode: response.statusCode, error: error, body: data)
            throw error
        }
    }

    private func send(_ request: URLRequest, feature: OptionalFeature? = nil, retries allowsRetry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let features = features
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.response(for: request, limit: ResponseLimit.api, scope: .account(rateLimit), retries: allowsRetry) {
                if let feature {
                    try await features.check(feature)
                }
            }
        } catch let error as URLError {
            requestLog.record(request, statusCode: nil, error: error, body: nil)
            throw error
        } catch let error as ResponseTooLarge {
            requestLog.record(request, statusCode: nil, error: error, body: nil)
            throw error
        }
        if (200..<300).contains(response.statusCode) {
            return (data, response)
        }
        if let feature, FeatureAvailability.indicatesUnsupported(statusCode: response.statusCode) {
            // 止めると決めた呼び出しも、止めた機能として失敗させる。呼び出し側が、ほかの失敗と分けて扱えるようにする。
            requestLog.record(request, statusCode: response.statusCode, error: MastodonAPIError.from(statusCode: response.statusCode, body: data), body: data)
            await features.disable(feature, statusCode: response.statusCode)
            throw FeatureUnavailable(feature: feature)
        }
        var failure = MastodonAPIError.from(statusCode: response.statusCode, body: data, retryAfter: RateLimitGate.retryAfter(of: response, now: now()))
        failure.account = RequestAccount(credential)
        requestLog.record(request, statusCode: response.statusCode, error: failure, body: data)
        throw failure
    }
}

/// インスタンスの設定のうち、Sciaが使うもの。
public struct InstanceConfiguration: Sendable, Equatable {
    /// 投稿の本文と注意書きを合わせた文字数の上限。
    public let maxCharacters: Int
    /// 本文中のURLを何文字と数えるか。
    public let charactersReservedPerURL: Int
    /// 1つの投稿に添付できるメディアの数。
    public let maxMediaAttachments: Int
    /// 代替テキストの文字数の上限。
    public let mediaDescriptionLimit: Int
    /// アップロードできるファイルのMIMEタイプ。返さないサーバーではnilで、送ってみるまで分からない。
    public let supportedMediaTypes: [String]?
    /// プロフィールの各項目の上限。
    public let profileLimits: ProfileLimits
    /// アップロードできるメディアの大きさの上限。
    public let mediaLimits: MediaLimits
    /// 投票の上限。
    public let pollLimits: PollLimits

    /// サーバーの値を読む前に使う上限。Mastodonの既定値にし、メディアの大きさの上限は分からないものとする。
    public static var beforeLoading: InstanceConfiguration {
        InstanceConfiguration(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown)
    }

    public init(
        maxCharacters: Int,
        charactersReservedPerURL: Int,
        maxMediaAttachments: Int,
        mediaDescriptionLimit: Int,
        supportedMediaTypes: [String]?,
        profileLimits: ProfileLimits = .beforeMastodon46,
        pollLimits: PollLimits = .mastodonDefault,
        mediaLimits: MediaLimits
    ) {
        self.maxCharacters = maxCharacters
        self.charactersReservedPerURL = charactersReservedPerURL
        self.maxMediaAttachments = maxMediaAttachments
        self.mediaDescriptionLimit = mediaDescriptionLimit
        self.supportedMediaTypes = supportedMediaTypes
        self.profileLimits = profileLimits
        self.pollLimits = pollLimits
        self.mediaLimits = mediaLimits
    }
}

/// アップロードするファイル。
public struct MediaUpload: Sendable, Equatable {
    public let data: Data
    public let filename: String
    /// Mastodonはファイルの部分にMIMEタイプが付いていることを求める。
    public let mimeType: String
    /// 代替テキスト。空なら送らない。
    public let description: String

    public init(data: Data, filename: String, mimeType: String, description: String = "") {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
        self.description = description
    }
}

/// アップロードした添付ファイルの、サーバーでの変換の状態。
public enum MediaProcessingState: Sendable, Equatable {
    case processing
    /// 変換が済み、`url`が入った。
    case processed(MediaAttachment)
}

/// 既読位置を保存できるタイムライン。
public enum MarkerTimeline: String, Sendable {
    case home
    case notifications
}

/// https://docs.joinmastodon.org/methods/notifications/#requests-merged
private struct MergedState: Decodable {
    let merged: Bool
}

/// https://docs.joinmastodon.org/entities/Marker/
struct Marker: Decodable {
    let lastReadId: String
}

/// アカウントの投稿の絞り込み。
public struct AccountStatusFilter: Sendable, Equatable {
    /// 他の人への返信を除く。本人への返信（自分のスレッドの続き）は、Mastodonでは除かれずに残る。
    public var excludesReplies: Bool
    public var excludesReblogs: Bool
    public var onlyMedia: Bool
    /// 固定された投稿だけを返す。
    public var pinned: Bool
    /// このハッシュタグの付いた投稿だけを返す。`#`を除いた名前。nilなら絞らない。
    public var tagged: String?

    public init(excludesReplies: Bool = false, excludesReblogs: Bool = false, onlyMedia: Bool = false, pinned: Bool = false, tagged: String? = nil) {
        self.excludesReplies = excludesReplies
        self.excludesReblogs = excludesReblogs
        self.onlyMedia = onlyMedia
        self.pinned = pinned
        self.tagged = tagged
    }

    var queryItems: [URLQueryItem] {
        let flags = [
            ("exclude_replies", excludesReplies),
            ("exclude_reblogs", excludesReblogs),
            ("only_media", onlyMedia),
            ("pinned", pinned),
        ].filter(\.1).map { URLQueryItem(name: $0.0, value: "true") }
        return flags + (tagged.map { [URLQueryItem(name: "tagged", value: $0)] } ?? [])
    }
}

/// タイムラインのどの範囲を読むか。
/// https://docs.joinmastodon.org/api/guidelines/#pagination
public struct TimelineQuery: Sendable, Equatable {
    /// これより古い投稿を返す。
    public var maxID: String?
    /// これより新しい投稿のうち、最も新しい側から返す。
    public var sinceID: String?
    /// これより新しい投稿のうち、すぐ後に続く側から返す。
    public var minID: String?
    public var limit: Int

    public init(maxID: String? = nil, sinceID: String? = nil, minID: String? = nil, limit: Int) {
        self.maxID = maxID
        self.sinceID = sinceID
        self.minID = minID
        self.limit = limit
    }

    var queryItems: [URLQueryItem] {
        [("max_id", maxID), ("since_id", sinceID), ("min_id", minID), ("limit", String(limit))].compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
    }
}

/// 人の一覧の種類。
public enum AccountListKind: Hashable, Sendable {
    /// 投稿をお気に入りした人。
    case favouritedBy(Status.ID)
    /// 投稿をブーストした人。
    case rebloggedBy(Status.ID)
    /// 投稿にその絵文字でリアクションした人。Fedibirdの拡張。`name`は絵文字の名前（Unicodeの絵文字か、カスタム絵文字のショートコード）。
    case emojiReactionedBy(Status.ID, name: String)
    /// アカウントのフォロワー。
    case followers(accountID: String)
    /// アカウントがプロフィールで紹介している人。Mastodon 4.4から。
    case endorsements(accountID: String)
    /// アカウントがフォローしている人。
    case following(accountID: String)
    /// 自分のリストのメンバー。
    case listMembers(listID: String)
}

/// 検索で探す種類。`rawValue`は`api/v2/search`の`type`に渡す値。
public enum SearchCategory: String, CaseIterable, Hashable, Sendable {
    case accounts
    case hashtags
    case statuses

    /// 結果の見出しと、その種類だけの一覧の題。
    public var title: String {
        switch self {
        case .accounts: "ユーザー"
        case .hashtags: "ハッシュタグ"
        case .statuses: "投稿"
        }
    }
}

/// 検索の結果。種類を絞って探したときも、サーバーは3つの種類を返し、絞った種類のほかは空にする。
/// https://docs.joinmastodon.org/entities/Search/
public struct SearchResults: Decodable, Sendable {
    public let accounts: [Account]
    /// サーバーが返す順。新しい順。
    public let statuses: [Status]
    /// 読めなかった投稿。読めた投稿と同じく並べ、ブラウザで開けるようにする。
    public let unreadableStatuses: [UnreadableItem]
    public let hashtags: [Hashtag]

    public init(accounts: [Account] = [], statuses: [Status] = [], unreadableStatuses: [UnreadableItem] = [], hashtags: [Hashtag] = []) {
        self.accounts = accounts
        self.statuses = statuses
        self.unreadableStatuses = unreadableStatuses
        self.hashtags = hashtags
    }

    private enum CodingKeys: String, CodingKey {
        case accounts, statuses, hashtags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent(ElementList<Account>.self, forKey: .accounts)?.elements ?? []
        let statuses = try container.decodeIfPresent(ElementList<Status>.self, forKey: .statuses)
        self.statuses = statuses?.elements ?? []
        unreadableStatuses = statuses?.unreadable ?? []
        hashtags = try container.decodeIfPresent(ElementList<Hashtag>.self, forKey: .hashtags)?.elements ?? []
    }

    /// 結果の件数。読めなかった投稿も数える。
    public func count(of category: SearchCategory) -> Int {
        switch category {
        case .accounts: accounts.count
        case .hashtags: hashtags.count
        case .statuses: statuses.count + unreadableStatuses.count
        }
    }
}

/// 人の一覧の1ページ分。
public struct AccountListPage: Sendable, Equatable {
    /// サーバーが返す順。
    public let accounts: [Account]
    /// 続きのページを読むときの`max_id`。`Link`ヘッダーに`next`がなければnilで、これより後ろはない。
    public let nextMaxID: String?

    public init(accounts: [Account], nextMaxID: String?) {
        self.accounts = accounts
        self.nextMaxID = nextMaxID
    }
}

/// タイムラインの1ページ分。
public struct TimelinePage: Sendable, Equatable {
    /// 新しい順。
    public let statuses: [Status]
    /// 読めなかった投稿。読めた投稿と同じく、並びと続きを読む位置に使う。
    public let unreadable: [UnreadableItem]
    /// サーバーがホームを再生成中で、結果が揃っていない。
    public let isRegenerating: Bool

    public init(statuses: [Status], unreadable: [UnreadableItem] = [], isRegenerating: Bool) {
        self.statuses = statuses
        self.unreadable = unreadable
        self.isRegenerating = isRegenerating
    }

    /// 読めたものと読めなかったものを合わせたID。
    var ids: [String] { statuses.map(\.id) + unreadable.map(\.id) }
    var count: Int { statuses.count + unreadable.count }
    var isEmpty: Bool { statuses.isEmpty && unreadable.isEmpty }
}

/// ブックマークやお気に入りの1ページ分。
public struct SavedStatusesPage: Sendable, Equatable {
    /// ブックマークした順、お気に入りした順の新しい順。投稿のIDの順とは限らない。
    public let statuses: [Status]
    /// 読めなかった投稿。応答の中の位置は分からないため、読めた投稿の後ろに並べる。
    public let unreadable: [UnreadableItem]
    /// 続きのページを読むときの`max_id`。`Link`ヘッダーに`next`がなければnilで、これより古いものはない。
    public let nextMaxID: String?

    public init(statuses: [Status], unreadable: [UnreadableItem] = [], nextMaxID: String?) {
        self.statuses = statuses
        self.unreadable = unreadable
        self.nextMaxID = nextMaxID
    }
}

/// 通知の1ページ分。
public struct NotificationPage: Sendable, Equatable {
    public let notifications: [MastodonNotification]
    /// 読めなかった通知。読めた通知と同じく、並びと続きを読む位置に使う。
    public let unreadable: [UnreadableItem]

    public init(notifications: [MastodonNotification], unreadable: [UnreadableItem] = []) {
        self.notifications = notifications
        self.unreadable = unreadable
    }

    /// 読めたものと読めなかったものを合わせたID。まとまりは、読んだ範囲の最も古い通知のIDも含める。続きを読む位置に使うため。
    var ids: [String] { notifications.flatMap { [$0.id, $0.pageMinID] } + unreadable.flatMap { [$0.id] + ($0.pageMinID.map { [$0] } ?? []) } }
    var count: Int { notifications.count + unreadable.count }
    var isEmpty: Bool { notifications.isEmpty && unreadable.isEmpty }
}

extension MastodonAPIError {
    /// 401。MastodonのREST APIでは、トークンが無効なとき（ログアウトされたとき）だけ返る。扱いは`AuthorizationCheck`にある。
    public var isUnauthorized: Bool { statusCode == 401 }
}

/// お知らせの一覧。読めなかったお知らせは、IDが読めれば`unreadable`に入る。
public struct AnnouncementList: Sendable, Equatable {
    public let announcements: [Announcement]
    public let unreadable: [UnreadableItem]

    public init(announcements: [Announcement], unreadable: [UnreadableItem] = []) {
        self.announcements = announcements
        self.unreadable = unreadable
    }
}
