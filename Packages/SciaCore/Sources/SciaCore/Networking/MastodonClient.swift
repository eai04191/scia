public import Foundation
import os

/// ログイン済みアカウントとしてMastodon APIを呼ぶ。
public struct MastodonClient: Sendable {
    public let credential: Credential
    private let transport: any HTTPTransport
    private let rateLimit: RateLimitGate
    private let features: FeatureAvailability
    private let retry: RetryPolicy
    private let requestLog: RequestLog
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
        requestLog: RequestLog = RequestLog(includesBody: false)
    ) {
        self.credential = credential
        self.transport = transport
        self.rateLimit = rateLimit
        self.features = features
        self.retry = retry
        self.requestLog = requestLog
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

    /// 通知を新しい順に返す。1回に読める件数の上限は80件。
    /// https://docs.joinmastodon.org/methods/notifications/#get
    public func notifications(_ query: TimelineQuery) async throws -> NotificationPage {
        let list = try await get(ElementList<MastodonNotification>.self, path: "api/v1/notifications", query: query.queryItems).0
        return NotificationPage(notifications: list.elements, unreadable: list.unreadable)
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

    /// https://docs.joinmastodon.org/methods/instance/#v2
    public func instanceConfiguration() async throws -> InstanceConfiguration {
        struct Instance: Decodable {
            struct Configuration: Decodable {
                struct URLs: Decodable {
                    let streaming: URL
                }
                struct Statuses: Decodable {
                    let maxCharacters: Int?
                    let maxMediaAttachments: Int?
                    let charactersReservedPerUrl: Int?
                }
                struct Accounts: Decodable {
                    let maxDisplayNameLength: Int?
                    let maxNoteLength: Int?
                    let maxProfileFields: Int?
                    let profileFieldNameLimit: Int?
                    let profileFieldValueLimit: Int?
                }
                struct Polls: Decodable {
                    let maxOptions: Int?
                    let maxCharactersPerOption: Int?
                    let minExpiration: Int?
                    let maxExpiration: Int?
                }
                struct MediaAttachments: Decodable {
                    let supportedMimeTypes: [String]?
                    let descriptionLimit: Int?
                    let imageSizeLimit: Int?
                    let imageMatrixLimit: Int?
                    let videoSizeLimit: Int?
                    let videoMatrixLimit: Int?
                    let videoFrameRateLimit: Int?
                }
                let urls: URLs
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
        return InstanceConfiguration(
            streamingURL: configuration.urls.streaming,
            maxCharacters: configuration.statuses?.maxCharacters ?? 500,
            charactersReservedPerURL: configuration.statuses?.charactersReservedPerUrl ?? 23,
            maxMediaAttachments: configuration.statuses?.maxMediaAttachments ?? 4,
            mediaDescriptionLimit: configuration.mediaAttachments?.descriptionLimit ?? 1500,
            supportedMediaTypes: configuration.mediaAttachments?.supportedMimeTypes,
            profileLimits: ProfileLimits(
                displayName: configuration.accounts?.maxDisplayNameLength ?? ProfileLimits.beforeMastodon46.displayName,
                note: configuration.accounts?.maxNoteLength ?? ProfileLimits.beforeMastodon46.note,
                fields: configuration.accounts?.maxProfileFields ?? ProfileLimits.beforeMastodon46.fields,
                fieldName: configuration.accounts?.profileFieldNameLimit ?? ProfileLimits.beforeMastodon46.fieldName,
                fieldValue: configuration.accounts?.profileFieldValueLimit ?? ProfileLimits.beforeMastodon46.fieldValue
            ),
            pollLimits: Self.pollLimits(configuration.polls.map { ($0.maxOptions, $0.maxCharactersPerOption, $0.minExpiration, $0.maxExpiration) }),
            // 上限はサーバーごとに変えられていることが多いので、返さない項目をMastodonの既定値で補わない。
            mediaLimits: MediaLimits(
                imageSizeLimit: configuration.mediaAttachments?.imageSizeLimit,
                imageMatrixLimit: configuration.mediaAttachments?.imageMatrixLimit,
                videoSizeLimit: configuration.mediaAttachments?.videoSizeLimit,
                videoMatrixLimit: configuration.mediaAttachments?.videoMatrixLimit,
                videoFrameRateLimit: configuration.mediaAttachments?.videoFrameRateLimit
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

            private enum CodingKeys: String, CodingKey {
                case visibility = "posting:default:visibility"
                case sensitive = "posting:default:sensitive"
                case expandsSpoilers = "reading:expand:spoilers"
            }
        }
        // キーにコロンを含むため、スネークケースからの変換を通さずに読む。
        let request = URLRequest(url: credential.instance.appending(path: "api/v1/preferences"))
        let (data, response) = try await send(request, feature: .preferences)
        let preferences = try decode(Preferences.self, from: data, of: response, for: request, using: JSONDecoder())
        // 返さない項目は、Mastodonの既定値を使う。
        return ServerPreferences(defaultVisibility: preferences.visibility ?? .public, defaultSensitive: preferences.sensitive ?? false, expandsSpoilers: preferences.expandsSpoilers ?? false)
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
        form += mediaIDs.map { URLQueryItem(name: "media_ids[]", value: $0) }
        if let poll = draft.poll {
            form += poll.formItems
        }
        return try await post(Status.self, path: "api/v1/statuses", form: form, headers: ["Idempotency-Key": draft.idempotencyKey]).0
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
    public func editStatus(_ target: StatusEditTarget, to draft: StatusDraft, now: Date = Date()) async throws -> Status {
        guard let form = draft.editForm(poll: target.poll, now: now) else { throw StatusPostError.attachmentsNotReady }
        return try await send(formRequest(method: "PUT", path: "api/v1/statuses/\(target.statusID)", form: form), decoding: Status.self).0
    }

    /// 自分の投稿を削除する。応答の中身は使わない。
    /// https://docs.joinmastodon.org/methods/statuses/#delete
    public func deleteStatus(_ statusID: Status.ID) async throws {
        var request = URLRequest(url: credential.instance.appending(path: "api/v1/statuses/\(statusID)"))
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

    /// 変換が済むまで、`pollInterval`ごとに状態を問い合わせて待つ。
    /// 待ち始めてから`timeout`を過ぎたら`MediaUploadError.processingTimedOut`を投げる。問い合わせにかかった時間も含めて数える。
    /// 問い合わせ1回の長さは通信の設定のタイムアウトに任せるので、最後の問い合わせの分だけ`timeout`を超えることがある。
    /// サーバーの添付ファイルは残るので、同じIDで待ち直せる。
    public func waitUntilProcessed(
        _ id: String,
        pollInterval: Duration = .seconds(1),
        timeout: Duration = .seconds(180)
    ) async throws -> MediaAttachment {
        try await waitUntilProcessed(id, pollInterval: pollInterval, timeout: timeout, clock: ContinuousClock())
    }

    func waitUntilProcessed<C: Clock<Duration>>(_ id: String, pollInterval: Duration, timeout: Duration, clock: C) async throws -> MediaAttachment {
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if case .processed(let attachment) = try await mediaProcessingState(id) {
                return attachment
            }
            guard clock.now.advanced(by: pollInterval) <= deadline else { throw MediaUploadError.processingTimedOut(serverID: id) }
            try await clock.sleep(for: pollInterval)
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

    /// https://docs.joinmastodon.org/methods/accounts/#get
    public func account(_ id: String) async throws -> Account {
        try await get(Account.self, path: "api/v1/accounts/\(id)", query: []).0
    }

    /// 自分と相手の関係。相手が見つからなければnil。
    /// https://docs.joinmastodon.org/methods/accounts/#relationships
    public func relationship(with id: String) async throws -> Relationship? {
        try await get([Relationship].self, path: "api/v1/accounts/relationships", query: [URLQueryItem(name: "id[]", value: id)]).0.first { $0.id == id }
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

    /// リストを作る。
    /// https://docs.joinmastodon.org/methods/lists/#create
    public func createList(title: String) async throws -> MastodonList {
        try await post(MastodonList.self, path: "api/v1/lists", form: [URLQueryItem(name: "title", value: title)]).0
    }

    /// リストを消す。
    /// https://docs.joinmastodon.org/methods/lists/#delete
    public func deleteList(_ listID: String) async throws {
        var request = URLRequest(url: credential.instance.appending(path: "api/v1/lists/\(listID)"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
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
        _ = try await post(Hashtag.self, path: "api/v1/tags/\(name)/follow", form: [])
    }

    /// ハッシュタグのフォローをやめる。フォローしていなくても成功する。
    /// https://docs.joinmastodon.org/methods/tags/#unfollow
    public func unfollowTag(_ name: String) async throws {
        _ = try await post(Hashtag.self, path: "api/v1/tags/\(name)/unfollow", form: [])
    }

    /// ハッシュタグのタイムラインを新しい順に返す。`name`は`#`を除いた名前。
    /// https://docs.joinmastodon.org/methods/timelines/#tag
    public func hashtagTimeline(_ name: String, _ query: TimelineQuery) async throws -> TimelinePage {
        let list = try await get(ElementList<Status>.self, path: "api/v1/timelines/tag/\(name)", query: query.queryItems).0
        return TimelinePage(statuses: list.elements, unreadable: list.unreadable, isRegenerating: false)
    }

    /// フォローしているハッシュタグをすべて返す。続きを`Link`ヘッダーで読み、最後まで読み切ってから返す。途中で読めなければ投げる。
    /// 読めない要素を捨てずに投げるのは、欠けた一覧で並びを書き換えると、読めなかったハッシュタグを並びから外してしまうため。
    /// 1回に読める件数の上限は200件。
    /// https://docs.joinmastodon.org/methods/followed_tags/#get
    public func followedTags() async throws -> [Hashtag] {
        var tags: [Hashtag] = []
        var maxID: String?
        repeat {
            let query = [URLQueryItem(name: "limit", value: "200")] + (maxID.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
            let (page, response) = try await get([Hashtag].self, path: "api/v1/followed_tags", query: query)
            tags += page
            let next = response.value(forHTTPHeaderField: "Link").map(LinkHeader.init)?.queryValue("max_id", of: "next")
            // 同じ位置を返し続けるサーバーで、同じページを読み続けないよう止める。
            maxID = next == maxID || page.isEmpty ? nil : next
        } while maxID != nil
        return tags
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

    /// `max_id`は投稿のIDではない内部のIDで、`Link`ヘッダーの`next`のURLにだけ書かれている。
    /// URLをそのまま開かず`max_id`だけを取り出すのは、トークンを付けて送る先を、ログインしたサーバーの決まったパスに限るため。
    private func savedStatuses(path: String, maxID: String?, limit: Int) async throws -> SavedStatusesPage {
        let query = [URLQueryItem(name: "limit", value: String(limit))] + (maxID.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
        let (list, response) = try await get(ElementList<Status>.self, path: path, query: query)
        let link = response.value(forHTTPHeaderField: "Link").map(LinkHeader.init)
        return SavedStatusesPage(statuses: list.elements, unreadable: list.unreadable, nextMaxID: link?.queryValue("max_id", of: "next"))
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
    public func searchAccountsForCompletion(_ query: String, limit: Int) async throws -> [Account] {
        let items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "resolve", value: "false"),
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

    /// プロフィールに載せているハッシュタグ。補完で、自分のタグとして先に出す。
    /// https://docs.joinmastodon.org/methods/featured_tags/#get
    public func featuredTags() async throws -> [FeaturedTag] {
        try await get(ElementList<FeaturedTag>.self, path: "api/v1/featured_tags", query: []).0.elements
    }

    /// 最近使ったハッシュタグ（最大10件）。補完で、自分のタグとして先に出す。
    /// サーバーは直近1年の最新1000投稿で2回以上使ったタグから、プロフィールに載せているものを除いて返す。
    /// https://docs.joinmastodon.org/methods/featured_tags/#suggestions
    public func featuredTagSuggestions() async throws -> [Hashtag] {
        try await get(ElementList<Hashtag>.self, path: "api/v1/featured_tags/suggestions", query: []).0.elements
    }

    /// サーバーで使えるカスタム絵文字の一覧。補完ではまとめて一度だけ取り、手元で絞る。
    /// https://docs.joinmastodon.org/methods/custom_emojis/
    public func customEmojis() async throws -> [ServerEmoji] {
        try await get(ElementList<ServerEmoji>.self, path: "api/v1/custom_emojis", query: []).0.elements
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

    /// 通知を1件削除する。応答の中身は使わない。
    /// https://docs.joinmastodon.org/methods/notifications/#dismiss
    public func dismissNotification(_ notificationID: MastodonNotification.ID) async throws {
        _ = try await send(formRequest(method: "POST", path: "api/v1/notifications/\(notificationID)/dismiss", form: []))
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
        let url = credential.instance.appending(path: path)
        return try await send(URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query)), decoding: type, feature: feature, retries: retries)
    }

    private func post<T: Decodable>(
        _ type: T.Type,
        path: String,
        form: [URLQueryItem],
        headers: [String: String] = [:],
        feature: OptionalFeature? = nil
    ) async throws -> (T, HTTPURLResponse) {
        try await send(formRequest(method: "POST", path: path, form: form, headers: headers), decoding: type, feature: feature)
    }

    private func formRequest(method: String, path: String, form: [URLQueryItem], headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: credential.instance.appending(path: path))
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
        let canRetry = allowsRetry && RetryPolicy.canRetry(request)
        var retries = 0
        while true {
            // 送り直しを待っている間に、並行する別の呼び出しが止めていることがある。
            if let feature {
                try await features.check(feature)
            }
            if RequestOrigin.current == .automatic {
                try await rateLimit.checkAutomaticRequest()
            }
            let isTemporary: Bool
            let failure: any Error
            var statusCode: Int?
            var body: Data?
            do {
                let (data, response) = try await transport.send(request)
                if (200..<300).contains(response.statusCode) {
                    return (data, response)
                }
                if let feature, FeatureAvailability.indicatesUnsupported(statusCode: response.statusCode) {
                    // 止めると決めた呼び出しも、止めた機能として失敗させる。呼び出し側が、ほかの失敗と分けて扱えるようにする。
                    requestLog.record(request, statusCode: response.statusCode, error: MastodonAPIError.from(statusCode: response.statusCode, body: data), body: data)
                    await features.disable(feature, statusCode: response.statusCode)
                    throw FeatureUnavailable(feature: feature)
                }
                var isPaused = false
                if response.statusCode == 429 || response.statusCode == 503 {
                    isPaused = await rateLimit.pause(respondingTo: response)
                }
                isTemporary = !isPaused && RetryPolicy.isTemporary(statusCode: response.statusCode)
                statusCode = response.statusCode
                body = data
                failure = MastodonAPIError.from(statusCode: response.statusCode, body: data)
            } catch let error as URLError {
                isTemporary = RetryPolicy.isTemporary(error)
                failure = error
            }
            guard canRetry, isTemporary, retries < retry.maxRetries else {
                requestLog.record(request, statusCode: statusCode, error: failure, body: body)
                throw failure
            }
            retries += 1
            // パスはIDを含むため残さない。
            Self.logger.info("request retry \(retries, privacy: .public) method=\(request.httpMethod ?? "GET", privacy: .public) reason=\(ErrorPresentation(failure).code ?? "unknown", privacy: .public)")
            try await Task.sleep(for: retry.delay(beforeRetry: retries))
        }
    }
}

/// インスタンスの設定のうち、Sciaが使うもの。
public struct InstanceConfiguration: Sendable, Equatable {
    public let streamingURL: URL
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

    public init(
        streamingURL: URL,
        maxCharacters: Int,
        charactersReservedPerURL: Int,
        maxMediaAttachments: Int,
        mediaDescriptionLimit: Int,
        supportedMediaTypes: [String]?,
        profileLimits: ProfileLimits = .beforeMastodon46,
        pollLimits: PollLimits = .mastodonDefault,
        mediaLimits: MediaLimits
    ) {
        self.streamingURL = streamingURL
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

    public init(excludesReplies: Bool = false, excludesReblogs: Bool = false, onlyMedia: Bool = false, pinned: Bool = false) {
        self.excludesReplies = excludesReplies
        self.excludesReblogs = excludesReblogs
        self.onlyMedia = onlyMedia
        self.pinned = pinned
    }

    var queryItems: [URLQueryItem] {
        [
            ("exclude_replies", excludesReplies),
            ("exclude_reblogs", excludesReblogs),
            ("only_media", onlyMedia),
            ("pinned", pinned),
        ].filter(\.1).map { URLQueryItem(name: $0.0, value: "true") }
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

    /// 読めたものと読めなかったものを合わせたID。
    var ids: [String] { notifications.map(\.id) + unreadable.map(\.id) }
    var count: Int { notifications.count + unreadable.count }
    var isEmpty: Bool { notifications.isEmpty && unreadable.isEmpty }
}

extension MastodonAPIError {
    /// 401。トークンが無効なことが多いが、一部のAPIだけを断るサーバーもあるため、ログインし直しが要るかは`AuthorizationCheck`で確かめる。
    public var isUnauthorized: Bool { statusCode == 401 }
}
