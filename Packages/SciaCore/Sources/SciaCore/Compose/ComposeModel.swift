public import Foundation
public import Observation
import os

/// 投稿欄の下書きの状態。
/// `Thumbnail`は、添付のサムネイルとして描く画像の型。iOSでは`UIImage`にする。切り抜きのプレビューのように、向きを持った画像をそのまま渡すため、`CGImage`にはしない。
@MainActor
@Observable
public final class ComposeModel<Thumbnail: Sendable> {
    public var text: String
    public var spoilerText: String
    /// 注意書きの欄を出している。隠しているときは注意書きなしで投稿する。
    /// 出していれば、注意書きが空でも、添付を閲覧注意にする。
    public var showsSpoiler: Bool
    public private(set) var visibility: Status.Visibility
    /// 返信先。新しい投稿と、編集ならnil。
    public private(set) var replyTo: Status?
    /// 引用する投稿。引用しなければnil。返信先とは一緒に付けない。決まりはdocs/quote.mdの「引用して投稿する」にある。
    public private(set) var quoteTarget: Status?
    /// 編集している自分の投稿。編集でなければnil。公開範囲と返信先は変えられない。
    public private(set) var editedStatus: Status?
    public private(set) var maxCharacters = InstanceConfiguration.beforeLoading.maxCharacters
    public private(set) var charactersReservedPerURL = InstanceConfiguration.beforeLoading.charactersReservedPerURL
    public private(set) var maxMediaAttachments = InstanceConfiguration.beforeLoading.maxMediaAttachments
    /// 代替テキストの文字数の上限。
    public private(set) var mediaDescriptionLimit = InstanceConfiguration.beforeLoading.mediaDescriptionLimit
    /// サーバーが受け付けるメディアの大きさの上限。読めるまでは分からないものとして、縮めない。
    @ObservationIgnored private var mediaLimits = InstanceConfiguration.beforeLoading.mediaLimits
    /// サーバーが受け付けると返した形式。返さないサーバーではnil。
    @ObservationIgnored private var supportedMediaTypes: [String]?
    /// 投稿ボタンを押してから、送り終えるか、送るのをやめるまで。添付の準備を待っている間も含む。
    public private(set) var isPosting = false
    /// 投稿ボタンを押したあと、添付の準備が済むのを待っている。決まりはdocs/compose.mdの「メディアの準備を待って送る」にある。
    public private(set) var isWaitingForMedia = false
    /// 送れなかった理由。投稿欄がアラートで出し、ログアウトされたアカウントがあればログインし直すボタンを添える。
    public var postError: ErrorPresentation?
    /// 添付したメディア。この順で投稿に並ぶ。
    public private(set) var attachments: [DraftAttachment] = [] {
        didSet { settleMediaWait() }
    }
    /// 付ける投票。投票の欄を出していなければnil。添付とは一緒に付けられないため、添付があるときは足せない。
    public var poll: PollDraft?
    /// サーバーが受け付ける投票の上限。読めるまではMastodonの既定値にする。
    public private(set) var pollLimits = InstanceConfiguration.beforeLoading.pollLimits
    /// 添付したメディアごとの、端末の側だけで持つもの。
    public private(set) var localMedia: [DraftAttachment.ID: LocalMedia<Thumbnail>] = [:] {
        didSet { settleMediaWait() }
    }
    /// 予約する日時。予約の行を出していなければnil。決まりはdocs/compose.mdの「予約投稿」にある。
    public private(set) var scheduledAt: Date?
    /// 書き直している予約。送れたら`onScheduleRewritten`で取り消させる。決まりはdocs/compose.mdの「書き直す」にある。
    public private(set) var rewritingSchedule: ScheduledStatus?
    /// 削除して書き直している自分の投稿。元の投稿は、送るときに削除する。決まりはdocs/compose.mdの「自分の投稿を削除して書き直す」にある。
    public private(set) var redraft: StatusRedraft?
    /// 投稿の言語のコード。nilなら送らず、サーバーに任せる。決まりはdocs/compose.mdの「投稿の言語」にある。
    public private(set) var language: String?
    /// アカウントの既定の言語。決めていないか、まだ読めていなければnil。
    public private(set) var defaultLanguage: String?

    /// 返信先から自動で入れた宛先と注意書き。返信先を替えたとき、自分で書いた部分と見分けるために使う。
    @ObservationIgnored private var initialDraft: StatusDraft
    /// 公開範囲を自分で選んだ。後から既定値が届いても上書きしない。
    private var hasChosenVisibility = false
    /// 言語を自分で選んだか、編集や予約の書き直しで元の言語を入れた。後から既定値が届いても上書きしない。
    @ObservationIgnored private var hasChosenLanguage = false
    /// 既定の公開範囲を読み終えた、または読めなかった。読み終えるまでは、既定より広い範囲で投稿しないよう、選ばない限り投稿させない。
    private var hasResolvedDefaults = false
    @ObservationIgnored private var defaultVisibility: Status.Visibility?
    /// アカウントの「既定で閲覧注意にする」。最初の添付を足したときに、注意書きの欄を開く。
    @ObservationIgnored private var defaultSensitive = false
    /// サーバーの上限を読めた。読めるまでは、添付の枚数の上限が分からないのでメディアを選ばせない。
    private var hasLoadedConfiguration = false
    /// ペーストか共有で入れた文字にあったURL。決まりはdocs/compose.mdの「URLの後ろに続いた文字」にある。
    @ObservationIgnored private var insertedURLs: [String] = []
    /// `insertedURLs`を忘れるたびに進める。忘れる前に読み始めたペーストを、読み終えたあとに覚えないため。
    @ObservationIgnored private var insertedGeneration = 0
    /// 最後に送った内容。同じ内容を送り直すときだけ同じIdempotency-Keyを使い、変えたら別の投稿として新しいキーにする。
    /// 応答だけが失われていた場合に、変えた内容が投稿されないまま成功扱いにならないようにするため。
    @ObservationIgnored private var lastSubmitted: StatusDraft?
    /// 書いているほかのアカウント。今のアカウントで書いていればnil。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
    public private(set) var otherAccount: ComposeAccount<Thumbnail>?
    /// 今のアカウントの、自分のアカウントのID。
    @ObservationIgnored private let homeAccountID: String
    /// 書いているアカウントの、そのサーバーでの自分のアカウントのID。
    public var myAccountID: String { otherAccount?.myAccountID ?? homeAccountID }
    /// 投稿するアカウントを替えたあと、新しいサーバーの上限を読むまで、アップロードし直すのを待っている添付。上限に合わせて縮め直すため。
    @ObservationIgnored private var awaitingReupload: Set<DraftAttachment.ID> = []
    /// 投稿するアカウントを替えた回数。替える前に始めたアップロードが、前のサーバーの結果を書き戻さないようにする。
    @ObservationIgnored private var accountGeneration = 0
    /// 予約の日時を決める今の日付。テストでは決まった日付に差し替える。
    @ObservationIgnored public var now: () -> Date = SystemTime.now
    /// 予約の日時を区切る暦。テストでは決まったタイムゾーンの暦に差し替える。
    @ObservationIgnored public var calendar = Calendar.autoupdatingCurrent
    @ObservationIgnored private let homeSubmit: (StatusDraft) async throws -> SubmittedDraft
    @ObservationIgnored private let homeMedia: ComposeMediaService<Thumbnail>
    private var media: ComposeMediaService<Thumbnail> { otherAccount?.media ?? homeMedia }
    /// 下書きの送信とアップロードの持ち主。セッションの持ち主の子で、ログアウトやアカウントの切り替えで閉じると、送っている途中のものも止める。
    @ObservationIgnored public let tasks: TaskScope
    /// 送っている途中にバックグラウンドへ移っても、送り終えるまでアプリを止めないよう頼む。終えるときに呼ぶものを返す。
    @ObservationIgnored private let backgroundTime: @MainActor (String) -> @MainActor () -> Void
    @ObservationIgnored private var uploadTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    /// 削除した元の投稿から外れるのを待っている添付。投稿の可否が変わるので、変更を見張れるようにする。
    private var releaseTasks: [DraftAttachment.ID: Task<Void, Never>] = [:] {
        didSet { settleMediaWait() }
    }
    @ObservationIgnored private let homeRedraftService: ComposeRedraftService
    /// 書いているアカウントのサーバーで、削除して書き直す元の投稿を消す口。
    private var redraftService: ComposeRedraftService { otherAccount?.redraft ?? homeRedraftService }
    /// 送っている間に、書き直している元の投稿を「削除」で消した。送るのをやめられるところでやめ、送り終えたら空に戻す。
    @ObservationIgnored private var stopsRedraftingAfterSubmit = false
    /// 代替テキストを送っている添付。送っている間は、書き戻してサーバーの値と同じになっても、送り終えるまで投稿させない。
    /// 送り終えた後のサーバーの値が、書き戻した値と違うことがあるため。投稿の可否が変わるので、変更を見張れるようにする。
    private var descriptionTasks: [DraftAttachment.ID: Task<Void, Never>] = [:] {
        didSet { settleMediaWait() }
    }
    /// 添付の準備を待っている投稿の続き。待っていなければnil。
    @ObservationIgnored private var mediaWait: CheckedContinuation<MediaWaitOutcome, Never>?
    @ObservationIgnored private var pickerSelection = MediaPickerSelection()
    @ObservationIgnored private let logger = SciaLog.logger(category: "compose")
    /// 今のアカウントで送れたとき、下書きを空に戻す前に、送った結果を渡して呼ぶ。投稿、予約、編集のどれだったかと、サーバーが返したものが入る。
    /// 一覧へ反映するのは呼ぶ側で、何をどこへ反映するかは`SubmittedDraft`の各場合にある。ほかのアカウントで送ったときは呼ばず、`ComposeAccount.onSubmitted`を呼ぶ。
    @ObservationIgnored public var onSubmitted: (SubmittedDraft) -> Void = { _ in }
    /// 投稿できて、下書きを空に戻したあとに呼ぶ。どのアカウントで送ったときも呼ぶ。
    @ObservationIgnored public var onPosted: () -> Void = {}
    /// 予約を書き直した投稿を送れて、`onPosted`を呼んだあとに、元の予約のIDを渡して呼ぶ。元の予約を取り消すのは呼ぶ側。
    @ObservationIgnored public var onScheduleRewritten: (ScheduledStatus.ID) -> Void = { _ in }
    /// 削除して書き直す元の投稿を削除できたら（もう消えていたときを含む）、そのIDを渡して呼ぶ。タイムラインから除くのは呼ぶ側。
    @ObservationIgnored public var onRedraftDeleted: (Status.ID) -> Void = { _ in }
    /// サーバーの上限のために、設定で選んだより小さく、または低い画質にした。使う人が選んでいない画質の変化なので、知らせる。
    @ObservationIgnored public var onMediaReduced: (MediaAttachment.Kind) -> Void = { _ in }
    /// ペーストしたメディアのうち、添付の上限を超えて足さなかったものの種類。
    @ObservationIgnored public var onPastedMediaSkipped: ([MediaAttachment.Kind]) -> Void = { _ in }
    /// 投稿するアカウントを替えたあとに呼ぶ。今のアカウントに戻ったらnil。呼ぶ側は、そのアカウントのサーバーの上限と既定値を`apply`で入れる。
    @ObservationIgnored public var onAccountChange: (ComposeAccount<Thumbnail>?) -> Void = { _ in }

    /// - Parameter submit: 下書きを今のアカウントのサーバーへ送る。ふつうは`AccountSession.client`の`MastodonClient.submit(_:)`を渡す。
    ///   投稿、予約、編集のどれで送るかは下書きの中身で決まり、そのクライアントで受けた401はセッションへ知らせる。送れた結果は`onSubmitted`に渡る。
    public init(
        tasks: TaskScope,
        replyTo: Status? = nil,
        myAccountID: String,
        media: ComposeMediaService<Thumbnail> = .unavailable,
        redraft redraftService: ComposeRedraftService = .unavailable,
        backgroundTime: @escaping @MainActor (String) -> @MainActor () -> Void,
        submit: @escaping (StatusDraft) async throws -> SubmittedDraft
    ) {
        self.tasks = tasks
        self.backgroundTime = backgroundTime
        let draft = replyTo.map { StatusDraft.reply(to: $0, myAccountID: myAccountID) } ?? StatusDraft()
        initialDraft = draft
        text = draft.text
        spoilerText = draft.spoilerText
        showsSpoiler = !draft.spoilerText.isEmpty
        visibility = draft.visibility
        self.replyTo = replyTo
        homeAccountID = myAccountID
        homeSubmit = submit
        homeMedia = media
        homeRedraftService = redraftService
    }

    /// 送る内容。注意書きの欄を隠していれば、注意書きは送らない。
    private var draftToPost: StatusDraft {
        var draft = initialDraft
        draft.text = text
        draft.spoilerText = showsSpoiler ? spoilerText : ""
        draft.hasSpoiler = showsSpoiler
        draft.visibility = visibility
        draft.attachments = attachments
        draft.poll = poll
        draft.scheduledAt = scheduledAt
        draft.language = language
        return draft
    }

    /// 既定と違う言語を選んでいる。前の言語のまま気づかずに送らないよう、コードを見せる。サーバーに任せているときは既定のままとみなす。
    public var choosesNonDefaultLanguage: Bool {
        language != nil && language != defaultLanguage
    }

    /// 言語を選ぶ。nilなら送らずにサーバーに任せる。
    public func choose(language: String?) {
        guard !isPosting else { return }
        self.language = language
        hasChosenLanguage = true
    }

    /// 添付を閲覧注意にして投稿する。
    public var isSensitive: Bool {
        draftToPost.sensitive
    }

    public var remainingCharacters: Int {
        maxCharacters - draftToPost.length(charactersReservedPerURL: charactersReservedPerURL)
    }

    /// 投稿ボタンを押せる。添付の準備が済んでいなくても、失敗したものがなければ押せ、済むのを待ってから送る。
    public var canPost: Bool {
        !isPosting && (hasResolvedDefaults || hasChosenVisibility || editedStatus != nil)
            && draftToPost.canSubmit(maxCharacters: maxCharacters, charactersReservedPerURL: charactersReservedPerURL, maxMediaAttachments: maxMediaAttachments, pollLimits: pollLimits)
            && !attachments.contains { attachmentStatus(of: $0.id) == .descriptionFailed }
    }

    /// 添付のアップロードと代替テキストの送信が全部済み、待たずに送れる。
    public var isMediaReady: Bool {
        descriptionTasks.isEmpty && draftToPost.mediaIDs != nil
    }

    /// メディアを選べる。枚数の上限をサーバーの値で読むまでは、ピッカーを開かない。
    /// 読めなかったときは、次に書き始めたときに読み直す。
    /// 編集している投稿の添付で上限まで埋まっていても開かない。ピッカーの上限の0は、選べないではなく上限なしを意味するため。
    /// 投票の欄を出している間と、引用している間も開かない。Mastodonは投票や引用と添付を一緒に付けられないため。
    public var canAttachMedia: Bool {
        !isPosting && hasLoadedConfiguration && pickerSelectionLimit > 0 && poll == nil && !isQuoting
    }

    /// メディアをペーストできる。ピッカーと違い、上限まで埋まっていても受け付け、入りきらない分を知らせる。
    /// 投票の欄を出している間と、引用している間は受け付けない。
    public var canPasteMedia: Bool {
        !isPosting && hasLoadedConfiguration && poll == nil && !isQuoting
    }

    /// 投票の欄を足せる。添付があるときと引用しているときは、Mastodonが一緒に付けられないため足せない。
    /// 編集では足せない。投票の付いた投稿の編集は、元の投票をそのまま送り直す。決まりはdocs/compose.mdの「自分の投稿の編集」にある。
    public var canAddPoll: Bool {
        !isPosting && attachments.isEmpty && editedStatus == nil && !isQuoting
    }

    /// 引用している。書き直している予約の引用は、引用元の投稿を持たずIDだけを持つ。
    public var isQuoting: Bool {
        quoteTarget != nil || initialDraft.quotedStatusID != nil
    }

    /// 返信している。書き直している予約の返信は、返信先の投稿を持たずIDだけを持つ。
    public var isReplying: Bool {
        replyTo != nil || initialDraft.inReplyToID != nil
    }

    /// 予約の行を足せる。Mastodonは編集の予約を受け付けないため、編集では足せない。
    public var canSchedule: Bool {
        !isPosting && editedStatus == nil
    }

    /// 予約の行を出す。日時は1時間より先の、いちばん近い正時にする。足せないときは何もしない。
    public func addSchedule() {
        guard scheduledAt == nil, canSchedule else { return }
        scheduledAt = ScheduledPosting.defaultDate(now: now(), calendar: calendar)
    }

    /// 予約の日時を変える。予約の行を出していなければ何もしない。
    public func setScheduledDate(_ date: Date) {
        guard !isPosting, scheduledAt != nil else { return }
        scheduledAt = date
    }

    /// 予約の行を外し、すぐ投稿する下書きに戻す。
    public func removeSchedule() {
        guard !isPosting else { return }
        scheduledAt = nil
    }

    /// 予約の日時として選べる最も早い日時。
    public var earliestScheduleDate: Date {
        ScheduledPosting.earliestDate(now: now(), calendar: calendar)
    }

    /// 投票の欄を出す。足せないときは何もしない。
    public func addPoll() {
        guard poll == nil, canAddPoll else { return }
        // 締め切りは1日にする。サーバーの上限の外なら、選べるもののうち最初のもの。
        let choices = PollDraft.expiryChoices(within: pollLimits)
        poll = PollDraft(expiresIn: choices.contains(86_400) ? 86_400 : choices.first ?? pollLimits.expirationRange.lowerBound)
    }

    /// 選択肢を書き換える。最後の欄に書くと上限まで空の欄が増え、後ろに空の欄が並ぶと詰める。決まりは`PollDraft.setOption`にある。
    public func setPollOption(_ text: String, at index: Int) {
        guard !isPosting else { return }
        poll?.setOption(text, at: index, limits: pollLimits)
    }

    /// 投票の欄を外す。書いた選択肢も捨てる。
    public func removePoll() {
        guard !isPosting else { return }
        poll = nil
    }

    /// 返信先か引用元と、既定値から決まる公開範囲。
    private var resolvedVisibility: Status.Visibility {
        let base = defaultVisibility ?? .public
        if let replyTo {
            return StatusDraft.reply(to: replyTo, myAccountID: myAccountID, defaultVisibility: base).visibility
        }
        if let quoteTarget {
            return StatusDraft.quote(of: quoteTarget, defaultVisibility: base).visibility
        }
        return base
    }

    /// 選べる公開範囲。引用元がフォロワー限定なら、それより広い範囲は選べない。サーバーが受け付けないため。
    public func canChoose(_ visibility: Status.Visibility) -> Bool {
        guard editedStatus == nil, !isPosting else { return false }
        guard let limit = quoteTarget.flatMap(StatusDraft.maxVisibility(quoting:)) else { return true }
        return visibility.narrower(limit) == visibility
    }

    /// インスタンスの上限と、ユーザーの既定の公開範囲、閲覧注意、言語を反映する。公開範囲と言語は、自分で選んでいたら変えない。
    /// 既定の閲覧注意は、この後に最初の添付を足したときから使う。
    /// - Parameter defaultLanguage: 既定の言語。読めなければnilで、今のままにする。既定を決めていなければ`.some(nil)`。
    /// - Parameter accountID: 値を読んだアカウントの`ComposeAccount.id`。今のアカウントならnil。読んでいる間に投稿するアカウントを替えていたら、何もしない。
    ///   前のアカウントのサーバーの上限や既定値で、替えたアカウントの下書きを決めないため。
    public func apply(configuration: InstanceConfiguration?, defaultVisibility: Status.Visibility?, defaultSensitive: Bool?, defaultLanguage: String?? = nil, accountID: String? = nil) {
        guard accountID == otherAccount?.id else { return }
        hasResolvedDefaults = true
        defer { startAwaitingReuploads() }
        if let defaultLanguage {
            self.defaultLanguage = defaultLanguage
            if !hasChosenLanguage {
                language = defaultLanguage
            }
        }
        if let configuration {
            applyLimits(configuration)
            hasLoadedConfiguration = true
        }
        if let defaultSensitive {
            self.defaultSensitive = defaultSensitive
        }
        guard let defaultVisibility else { return }
        self.defaultVisibility = defaultVisibility
        guard !hasChosenVisibility, editedStatus == nil else { return }
        visibility = resolvedVisibility
    }

    private func applyLimits(_ configuration: InstanceConfiguration) {
        maxCharacters = configuration.maxCharacters
        charactersReservedPerURL = configuration.charactersReservedPerURL
        maxMediaAttachments = configuration.maxMediaAttachments
        mediaDescriptionLimit = configuration.mediaDescriptionLimit
        mediaLimits = configuration.mediaLimits
        pollLimits = configuration.pollLimits
        supportedMediaTypes = configuration.supportedMediaTypes
    }

    /// 編集では公開範囲を変えられないため、選んでも変えない。引用元より広い範囲も変えない。
    public func choose(_ visibility: Status.Visibility) {
        guard canChoose(visibility) else { return }
        self.visibility = visibility
        hasChosenVisibility = true
    }

    /// 本文のうち、返信先から自動で入れた宛先を除いた、自分で書いた部分。宛先を書き換えていたら本文全体。
    /// 編集では、元の本文も自分で書いたものなので本文全体。
    public var typedText: String {
        guard editedStatus == nil, rewritingSchedule == nil, redraft == nil else { return text }
        return text.hasPrefix(initialDraft.text) ? String(text.dropFirst(initialDraft.text.count)) : text
    }

    /// 編集のラベルの文字。返信の編集なら、誰への返信かも書く。返信先はメンションの中から探し、見つからなければ相手を書かない。
    public var editChipTitle: String? {
        guard let editedStatus else { return nil }
        guard editedStatus.inReplyToId != nil else { return "投稿を編集中" }
        if editedStatus.inReplyToAccountId == myAccountID { return "自分への返信を編集中" }
        guard let acct = editedStatus.mentions.first(where: { $0.id == editedStatus.inReplyToAccountId })?.acct else { return "返信を編集中" }
        return "@\(acct)への返信を編集中"
    }

    /// 返信先を付け替える。nilなら新しい投稿に戻す。
    ///
    /// 自分で書いた本文は残し、前の返信先から自動で入れた宛先だけを入れ替える。宛先を書き換えていたら、本文はそのまま残して新しい宛先を前に足す。
    /// 注意書きも、前の返信先から引き継いだままなら入れ替え、自分で書き換えていれば残す。引き継いだ注意書きがないのに欄を出していれば、自分で開いた欄なので、空でも残す（添付の閲覧注意を外さないため）。
    /// 公開範囲は選び直しにする。新しい投稿で選んだ公開範囲のまま、フォロワー限定の投稿へ公開で返信してしまわないため。
    ///
    /// 送信を待つ間は変えない。送っている下書きと食い違い、成功して空に戻すときに新しい返信先まで消してしまうため。
    /// 同じ投稿を選び直したときも変えない。失敗した投稿を同じIdempotency-Keyで送り直せるようにするため。
    /// 返信と引用は一緒に付けないため、引用していれば外す。
    public func setReplyTarget(_ status: Status?) {
        guard !isPosting else { return }
        // 同じ投稿を元の投稿とブーストのように別の場所から選び直したときは、下書きを保ったまま、ラベルが指す先だけを選んだ方にする。
        if let status, status.displayed.id == replyTo?.displayed.id {
            replyTo = status
            return
        }
        guard status != nil || replyTo != nil else { return }
        retarget(to: status.map { StatusDraft.reply(to: $0, myAccountID: myAccountID) } ?? StatusDraft(), replyTo: status, quoteTarget: nil)
    }

    /// 引用元を付け替える。nilなら引用をやめる。返信と引用は一緒に付けないため、返信先があれば外す。
    /// 自分で書いた本文と注意書き、公開範囲の扱いは、返信先を付け替えるときと同じ。
    /// Mastodonは引用に添付と投票を付けられないため、付けるときは添付と投票を外す。外してよいかは、呼ぶ側が先に聞く。
    public func setQuoteTarget(_ status: Status?) {
        guard !isPosting else { return }
        if let status, status.displayed.id == quoteTarget?.displayed.id {
            quoteTarget = status
            return
        }
        guard status != nil || quoteTarget != nil else { return }
        if status != nil {
            removeAllAttachments()
            poll = nil
        }
        retarget(to: status.map { StatusDraft.quote(of: $0) } ?? StatusDraft(), replyTo: nil, quoteTarget: status)
    }

    /// 引用を付けると外れる、添付か投票がある。
    public var hasQuoteConflicts: Bool {
        !attachments.isEmpty || poll != nil
    }

    /// 返信先と引用元を入れ替え、前の返信先から自動で入れた宛先と注意書きだけを入れ替える。
    private func retarget(to draft: StatusDraft, replyTo: Status?, quoteTarget: Status?) {
        let typed = typedText
        let keepsSpoiler = showsSpoiler && (spoilerText != initialDraft.spoilerText || initialDraft.spoilerText.isEmpty)
        initialDraft = draft
        self.replyTo = replyTo
        self.quoteTarget = quoteTarget
        text = initialDraft.text + typed
        if !keepsSpoiler {
            spoilerText = initialDraft.spoilerText
            showsSpoiler = !spoilerText.isEmpty
        }
        lastSubmitted = nil
        hasChosenVisibility = false
        visibility = resolvedVisibility
    }

    /// 書き直しのラベルの文字。返信か引用の予約なら、そう書く。返信先と引用元の投稿は持たないので、相手は書かない。
    public var rewriteChipTitle: String? {
        guard rewritingSchedule != nil else { return nil }
        if initialDraft.quotedStatusID != nil { return "予約した引用を書き直し中" }
        if initialDraft.inReplyToID != nil { return "予約した返信を書き直し中" }
        return "予約を書き直し中"
    }

    /// 削除して書き直すラベルの文字。返信か引用なら、そう書く。元の投稿を削除したあとは、もうないことが分かるように書く。
    /// 返信先と引用元の投稿は持たないので、相手は書かない。
    public var redraftChipTitle: String? {
        guard let redraft else { return nil }
        if redraft.deletion == .done { return "削除した投稿を書き直し中" }
        if initialDraft.quotedStatusID != nil { return "引用を削除して書き直し中" }
        if initialDraft.inReplyToID != nil { return "返信を削除して書き直し中" }
        return "削除して書き直し中"
    }

    /// 捨てると失われる、自分で書いたものがある。編集と予約の書き直しは書き換えていなくても、始めたこと自体を失うものとして扱う。
    /// 返信先から自動で入れた宛先と注意書きは数えない。
    public var hasWrittenContent: Bool {
        editedStatus != nil
            || rewritingSchedule != nil
            || redraft != nil
            || !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || (!spoilerText.isEmpty && spoilerText != initialDraft.spoilerText)
            || !(poll?.filledOptions.isEmpty ?? true)
    }

    /// 下書きを捨てて空の状態（`reset()`のあと）に戻せる。空の状態のときと、送っている間は戻せない。送れなかったときに送り直せるよう、下書きを残すため。
    public var canDiscardDraft: Bool {
        guard !isPosting else { return false }
        return hasWrittenContent
            || !text.isEmpty
            || !spoilerText.isEmpty
            || replyTo != nil
            || quoteTarget != nil
            || showsSpoiler
            || poll != nil
            || scheduledAt != nil
            || visibility != resolvedVisibility
            // 言語のバッジの判定（`choosesNonDefaultLanguage`）は、サーバーに任せる（nil）を既定扱いにするため使わない。
            || language != defaultLanguage
    }

    /// ペーストを読み始めたときの下書き。読み終えたら`noteInsertedText(_:token:)`に渡す。
    public var insertedTextToken: InsertedTextToken {
        InsertedTextToken(generation: insertedGeneration)
    }

    /// ペーストか共有で入れた文字のURLを覚える。決まりはdocs/compose.mdの「URLの後ろに続いた文字」にある。
    /// - Parameter token: 読み始めたときの`insertedTextToken`。そのあと下書きを空に戻すか本文を入れ替えていたら、覚えない。
    public func noteInsertedText(_ inserted: String, token: InsertedTextToken? = nil) {
        guard token == nil || token == insertedTextToken else { return }
        for url in LinkTitling.urls(in: inserted) where !insertedURLs.contains(where: { $0.utf8.elementsEqual(url.utf8) }) {
            insertedURLs.append(url)
        }
    }

    /// 本文のURLのうち、ペーストか共有で入れたURLの後ろに文字が続いたもの。
    public var extendedURLs: [ExtendedURL] {
        ExtendedURL.find(in: text, inserted: insertedURLs)
    }

    private func forgetInsertedURLs() {
        insertedURLs = []
        insertedGeneration += 1
    }

    /// `extendedURLs`の続いた文字の前に改行を入れる。
    public func separateExtendedURLs() {
        text = ExtendedURL.separating(extendedURLs, in: text)
    }

    /// 自分の投稿の編集を始める。今の下書きは捨てる。送っている間は始めずfalseを返す。
    /// 投票を送り直せない投稿（締め切りまで5分を切った）でも、下書きを変えずにfalseを返す。
    /// 本文と注意書きは、HTMLの`content`ではなく、書いたときのソースから入れる。
    @discardableResult
    /// - Parameter account: 投稿を書いたアカウント。今のアカウントならnil。投稿するアカウントをそのアカウントにしてから始める。
    public func beginEditing(_ status: Status, source: StatusSource, now: Date = SystemTime.now(), as account: ComposeAccount<Thumbnail>? = nil) -> Bool {
        guard !isPosting, let draft = StatusDraft.edit(of: status, source: source, now: now) else { return false }
        enterAccount(account)
        removeAllAttachments()
        initialDraft = draft
        editedStatus = status
        replyTo = nil
        quoteTarget = nil
        text = draft.text
        spoilerText = draft.spoilerText
        showsSpoiler = draft.hasSpoiler
        visibility = draft.visibility
        attachments = draft.attachments
        poll = nil
        scheduledAt = nil
        rewritingSchedule = nil
        redraft = nil
        language = draft.language
        hasChosenLanguage = true
        forgetInsertedURLs()
        lastSubmitted = nil
        hasChosenVisibility = false
        return true
    }

    /// 予約した投稿を書き直し始める。今の下書きは捨てる。送っている間は始めずfalseを返す。
    /// 予約したときの内容と日時を戻す。元の予約は、送れたあとに取り消させる。
    @discardableResult
    public func beginRewriting(_ scheduled: ScheduledStatus) -> Bool {
        guard !isPosting else { return false }
        leaveOtherAccount()
        // 公開範囲を送っていない予約は、既定の公開範囲にする。まだ届いていなければ、届いたときに`apply`が入れ直す。
        let draft = StatusDraft.rewrite(of: scheduled, defaultVisibility: defaultVisibility ?? .public)
        removeAllAttachments()
        initialDraft = draft
        editedStatus = nil
        replyTo = nil
        quoteTarget = nil
        text = draft.text
        spoilerText = draft.spoilerText
        showsSpoiler = draft.hasSpoiler
        visibility = draft.visibility
        attachments = draft.attachments
        // 予約から戻した添付は端末にファイルがなく、サーバーのメディアで描く。代替テキストを送れなかったことは、ほかの添付と同じくここに持つ。
        // 読み直すファイルがないので、読み込みを送り直すことはない。
        for attachment in draft.attachments {
            localMedia[attachment.id] = LocalMedia(assetIdentifier: nil) { _ in throw CocoaError(.fileNoSuchFile) }
        }
        poll = draft.poll
        scheduledAt = draft.scheduledAt
        rewritingSchedule = scheduled
        redraft = nil
        // 言語を送っていない予約は、送らずにサーバーに任せたままにする。
        language = draft.language
        hasChosenLanguage = true
        forgetInsertedURLs()
        lastSubmitted = nil
        // 予約したときの公開範囲を、あとから届く既定の公開範囲で上書きしない。公開範囲を送っていない予約は、既定の公開範囲が届くのを待つ。
        hasChosenVisibility = scheduled.params.visibility != nil
        return true
    }

    /// 自分の投稿を削除して書き直し始める。今の下書きは捨てる。送っている間は始めずfalseを返す。
    /// 元の投稿は、送るときに削除する。本文と注意書きは、HTMLの`content`ではなく、書いたときのソースから入れる。
    @discardableResult
    /// - Parameter account: 投稿を書いたアカウント。今のアカウントならnil。投稿するアカウントをそのアカウントにしてから始める。
    /// - Parameter configuration: `account`のサーバーの上限。読めていれば渡す。投票の締め切りを、そのサーバーで選べるものにするため。
    ///   アカウントを替えると上限は読む前の値に戻り、あとから`apply`で読んでも、決めた締め切りは選び直さない。
    public func beginRedrafting(_ status: Status, source: StatusSource, as account: ComposeAccount<Thumbnail>? = nil, configuration: InstanceConfiguration? = nil) -> Bool {
        guard !isPosting else { return false }
        enterAccount(account)
        if let configuration {
            applyLimits(configuration)
            hasLoadedConfiguration = true
        }
        let draft = StatusDraft.redraft(of: status, source: source, pollLimits: pollLimits)
        removeAllAttachments()
        initialDraft = draft
        editedStatus = nil
        replyTo = nil
        quoteTarget = nil
        text = draft.text
        spoilerText = draft.spoilerText
        showsSpoiler = draft.hasSpoiler
        visibility = draft.visibility
        attachments = draft.attachments
        // 元の投稿の添付は端末にファイルがなく、サーバーのメディアで描く。予約の書き直しと同じく、読み直すファイルはない。
        for attachment in draft.attachments {
            localMedia[attachment.id] = LocalMedia(assetIdentifier: nil) { _ in throw CancellationError() }
        }
        poll = draft.poll
        scheduledAt = nil
        rewritingSchedule = nil
        redraft = StatusRedraft(status: status)
        language = draft.language
        hasChosenLanguage = true
        forgetInsertedURLs()
        lastSubmitted = nil
        // 元の投稿の公開範囲を、あとから届く既定の公開範囲で上書きしない。
        hasChosenVisibility = true
        return true
    }

    /// 下書きを空にして、返信先のない新しい投稿に戻す。編集していれば、編集をやめる。
    /// ほかのアカウントで書いていれば、今のアカウントに戻す。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
    public func reset() {
        leaveOtherAccount()
        initialDraft = StatusDraft()
        replyTo = nil
        quoteTarget = nil
        editedStatus = nil
        text = ""
        spoilerText = ""
        showsSpoiler = false
        poll = nil
        scheduledAt = nil
        rewritingSchedule = nil
        redraft = nil
        removeAllAttachments()
        forgetInsertedURLs()
        lastSubmitted = nil
        hasChosenVisibility = false
        visibility = resolvedVisibility
        // 選んだ言語を次の投稿に残さない。たまに英語で書いたあとの投稿まで、英語として送らないため。
        hasChosenLanguage = false
        language = defaultLanguage
    }

    /// 投稿するアカウントを替える。nilなら今のアカウントに戻す。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
    /// 書いた本文、注意書き、投票、予約、言語は残す。返信先と引用元は、前のアカウントのサーバーでのIDなので外す。
    /// 添付は、新しいサーバーの上限を`apply`で読んでから、そのサーバーへアップロードし直す。
    /// 送っている間と、編集、削除して書き直す、予約の書き直しの間は替えずにfalseを返す。どれも前のアカウントのサーバーの投稿を指すため。
    /// 編集と書き直しを、そのアカウントの投稿で始めるときは、`beginEditing`と`beginRedrafting`にアカウントを渡す。
    @discardableResult
    public func switchAccount(to account: ComposeAccount<Thumbnail>?) -> Bool {
        guard !isPosting, editedStatus == nil, redraft == nil, rewritingSchedule == nil else { return false }
        guard account?.id != otherAccount?.id else { return true }
        // 添付はみな、端末のファイルから選んだかペーストしたもの。編集や書き直しの添付は、上で替えないので来ない。
        guard attachments.allSatisfy({ localMedia[$0.id] != nil }) else { return false }
        otherAccount = account
        if replyTo != nil || quoteTarget != nil {
            retarget(to: StatusDraft(), replyTo: nil, quoteTarget: nil)
        }
        lastSubmitted = nil
        forgetServerDefaults()
        for attachment in attachments {
            prepareReupload(attachment.id)
        }
        onAccountChange(account)
        return true
    }

    /// ほかのアカウントで書いていれば、今のアカウントに戻す。下書きを空にするときに呼ぶ。
    private func leaveOtherAccount() {
        enterAccount(nil)
    }

    /// 投稿するアカウントを`account`にする。編集や書き直しを始めるときと、下書きを空にするときに呼ぶ。
    /// どれも添付を捨てるので、`switchAccount`と違ってアップロードし直さない。
    private func enterAccount(_ account: ComposeAccount<Thumbnail>?) {
        guard account?.id != otherAccount?.id else { return }
        otherAccount = account
        forgetServerDefaults()
        onAccountChange(account)
    }

    /// 前のアカウントのサーバーの上限と既定値を忘れ、読む前の値に戻す。新しいアカウントの値を`apply`で読むまで、既定より広い範囲で投稿させず、メディアを選ばせない。
    /// 読めなかったときも、前のサーバーの上限で本文の長さや添付の大きさを決めないため。
    private func forgetServerDefaults() {
        accountGeneration += 1
        hasResolvedDefaults = false
        hasLoadedConfiguration = false
        defaultVisibility = nil
        applyLimits(.beforeLoading)
    }

    /// 新しいサーバーの上限で縮め直してアップロードし直すまで待たせる。前のサーバーへのアップロードは止めずに、送る前と応答を受けたところで抜けさせる（`upload`）。
    /// 止めると、読み込んでいる途中のファイルや書き出している途中の動画を、止めた処理が消し、同じ読み込みや書き出し先を使う送り直しまで失敗するため。
    private func prepareReupload(_ id: DraftAttachment.ID) {
        descriptionTasks.removeValue(forKey: id)?.cancel()
        localMedia[id]?.failure = nil
        localMedia[id]?.descriptionFailure = nil
        localMedia[id]?.progress = 0
        setState(.uploading, of: id)
        awaitingReupload.insert(id)
    }

    /// 投稿するアカウントを替えたあと、新しいサーバーの上限を読んだら、待たせていた添付をアップロードし直す。読めなかったときも、読む前の上限のまま送る。
    /// 前のサーバーへの処理が抜けるのを待ってから、前の上限で作り直したファイルを捨てて、作り直す。
    private func startAwaitingReuploads() {
        let waiting = awaitingReupload
        awaitingReupload = []
        for attachment in attachments where waiting.contains(attachment.id) {
            let id = attachment.id
            let previous = uploadTasks[id]
            uploadTasks[id] = tasks.run(.action) { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled else { return }
                discardPreparedFile(of: id)
                await upload(id)
            }
        }
    }

    /// 前のサーバーの上限に合わせて作り直したファイルを捨てる。読み込んだファイルはそのまま使う。
    private func discardPreparedFile(of id: DraftAttachment.ID) {
        if let local = localMedia[id], let sending = local.sending, sending.url != local.file?.url {
            try? FileManager.default.removeItem(at: sending.url)
        }
        localMedia[id]?.sending = nil
        localMedia[id]?.sendingIsReencoded = false
        localMedia[id]?.reduction = nil
    }

    /// 編集には`Idempotency-Key`を付けないため、そのまま送る。同じ編集を送り直しても、サーバーは変化がなければ編集として残さない。
    private func submission(of draft: StatusDraft) -> StatusDraft {
        guard draft.editing == nil, let lastSubmitted else { return draft }
        if lastSubmitted.text == draft.text, lastSubmitted.spoilerText == draft.spoilerText, lastSubmitted.sensitive == draft.sensitive,
           lastSubmitted.visibility == draft.visibility, lastSubmitted.mediaIDs == draft.mediaIDs, lastSubmitted.poll == draft.poll,
           lastSubmitted.scheduledAt == draft.scheduledAt, lastSubmitted.language == draft.language {
            return lastSubmitted
        }
        return StatusDraft(text: draft.text, spoilerText: draft.spoilerText, hasSpoiler: draft.hasSpoiler, visibility: draft.visibility, inReplyToID: draft.inReplyToID, quotedStatusID: draft.quotedStatusID, attachments: draft.attachments, poll: draft.poll, scheduledAt: draft.scheduledAt, language: draft.language)
    }

    /// 投稿し、成功したら下書きを空に戻す。失敗したら下書きを残し、同じ下書きで送り直せるようにする。
    /// 予約の日時が今から5分より後でなければ送らずに知らせる。サーバーは過去の日時を断らずにすぐ投稿するため。
    /// 添付の準備が済んでいなければ、済むまで待ってから送る。待っている間に失敗したら送らずに知らせ、待つのをやめたら何もしない。
    /// 予約の日時は、押したときと送る直前の両方で確かめる。待っている間に近づくことがあるため。
    public func submit() async {
        guard canPost, acceptsSchedule() else { return }
        UserAction.submitPost.record()
        isPosting = true
        let endBackgroundTime = backgroundTime("post status")
        defer {
            isPosting = false
            endBackgroundTime()
            if stopsRedraftingAfterSubmit {
                stopsRedraftingAfterSubmit = false
                reset()
            }
        }
        // 削除したあとに送れなかった書き直しでは、元の投稿から外れたと分かっていない添付を、待ち直す。
        startReleasingRedraftMedia()
        guard await waitForMediaToPost(), acceptsSchedule(), !stopsRedraftingAfterSubmit else { return }
        // 削除して書き直すときは、新しく足した添付の準備が済んでから元の投稿を削除し、元の投稿から外れた添付を付けて送る。
        // 準備に失敗して送れないまま、元の投稿だけが消えないようにするため。
        if let redraft, redraft.deletion != .done {
            guard await deleteRedraftedStatus(redraft.status.id), !stopsRedraftingAfterSubmit else { return }
            startReleasingRedraftMedia()
            guard await waitForMediaToPost(), acceptsSchedule() else { return }
        }
        let draft = submission(of: draftToPost)
        lastSubmitted = draft
        // 送っている間は投稿するアカウントを替えさせないが、送り終えたときに知らせる先を、送ったアカウントに決めておく。
        let account = otherAccount
        do {
            let submitted = try await (account?.submit ?? homeSubmit)(draft)
            if let account {
                account.onSubmitted(submitted)
            } else {
                onSubmitted(submitted)
            }
            let rewritten = rewritingSchedule?.id
            reset()
            onPosted()
            if let rewritten {
                onScheduleRewritten(rewritten)
            }
        } catch {
            // 編集は応答だけを失っても、代替テキストはサーバーに届いていることがある。元の値に戻して送り直しても届くよう、送った添付に目印を付ける。
            let sentIDs = Set(draft.changedAttachedDescriptions.map(\.id))
            for index in attachments.indices where attachments[index].serverID.map(sentIDs.contains) ?? false {
                attachments[index].hasUnconfirmedDescription = true
            }
            postError = ErrorPresentation(error)
        }
    }

    /// 添付の準備が済むのを待ち、送れるならtrueを返す。失敗したら知らせ、待つのをやめたら何も知らせない。
    private func waitForMediaToPost() async -> Bool {
        switch await waitForMedia() {
        case .ready:
            return true
        case .cancelled:
            logger.info("compose: stopped waiting for media")
            return false
        case .failed:
            logger.info("compose: media failed while waiting to post")
            let release = attachments.lazy.compactMap { [localMedia] attachment in
                attachment.isHeldByRedraftedStatus ? localMedia[attachment.id]?.failure : nil
            }.first
            postError = release.map { ErrorPresentation($0).leading("元の投稿を削除しましたが、投稿しませんでした。") }
                ?? ErrorPresentation(message: "メディアを送信できなかったため、投稿しませんでした。", code: nil)
            return false
        }
    }

    /// 書き直している元の投稿が、書き直しの外で削除されたと分かったときに呼ぶ（ストリーミングで知った、この端末の「削除」で消したなど）。
    /// 元の投稿はもうないので、やめる前に確かめ、送るときは削除せずに続ける。
    /// - Parameter stopsRedrafting: この端末の「削除」で消したならtrue。添付も消え、書き直した投稿に付けられないので、書き直しをやめる。
    ///   送るのを待っている間なら、待つのをやめ、送るのをやめてから空に戻す。もう投稿を送り始めていれば、送り終えてから空に戻す。
    /// - Parameter accountID: 消えた投稿のアカウントの`ComposeAccount.id`。今のアカウントならnil。書いているアカウントと違えば、IDが同じでも別の投稿なので何もしない。
    public func redraftedStatusWasDeleted(_ id: Status.ID, stopsRedrafting: Bool, accountID: String? = nil) {
        guard accountID == otherAccount?.id, redraft?.status.id == id else { return }
        redraft?.deletion = .done
        guard stopsRedrafting else { return }
        guard isPosting else {
            reset()
            return
        }
        stopsRedraftingAfterSubmit = true
        cancelWaitingForMedia()
    }

    /// 削除して書き直す元の投稿を、添付を残して削除する。削除できたら（もう消えていたときを含む）trueを返す。
    /// サーバーが断ったら元の投稿は残っているので、書き直しを続けられる。応答を受け取れなかったら、届いたか分からないものとして、送り直すときに削除から送り直す。
    private func deleteRedraftedStatus(_ id: Status.ID) async -> Bool {
        logger.info("compose: deleting redrafted status")
        do {
            try await redraftService.deleteStatus(id)
        } catch let error as MastodonAPIError where error.statusCode == 404 {
            logger.info("compose: redrafted status already gone")
        } catch let error as MastodonAPIError where error.statusCode < 500 {
            logger.error("compose: redrafted status delete refused: \(SciaLog.describe(error), privacy: .public)")
            postError = ErrorPresentation(error).leading("元の投稿を削除できなかったため、投稿しませんでした。")
            return false
        } catch {
            // 5xxは、届いたか分からないものとして扱う。Mastodonは投稿を消してから応答を返すので、プロキシの502や504でも消えていることがあるため。
            logger.error("compose: redrafted status delete unknown: \(SciaLog.describe(error), privacy: .public)")
            // 待つ間にストリーミングで消えたと分かっていれば、それを残す。
            if redraft?.deletion != .done {
                redraft?.deletion = .uncertain
            }
            guard !(error is CancellationError) else { return false }
            postError = ErrorPresentation(error).leading("元の投稿を削除できたか分からないため、投稿しませんでした。送り直すと削除から送り直します。")
            return false
        }
        redraft?.deletion = .done
        if let otherAccount {
            otherAccount.onRedraftDeleted(id)
        } else {
            onRedraftDeleted(id)
        }
        return true
    }

    /// 元の投稿を削除したあと、まだ元の投稿に付いている添付が外れるのを待ち始める。外れたら、書き換えた代替テキストを送る。
    /// 削除する前と、もう待っている添付では何もしない。
    private func startReleasingRedraftMedia() {
        guard redraft?.deletion == .done else { return }
        for attachment in attachments where attachment.isHeldByRedraftedStatus && releaseTasks[attachment.id] == nil {
            guard let serverID = attachment.serverID else { continue }
            let id = attachment.id
            localMedia[id]?.failure = nil
            releaseTasks[id] = tasks.run(.action) { [weak self, redraftService] in
                do {
                    let released = try await redraftService.waitUntilReleased(serverID)
                    guard let self, !Task.isCancelled, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
                    attachments[index].state = .uploaded(released)
                    attachments[index].isHeldByRedraftedStatus = false
                    releaseTasks[id] = nil
                    sendDescriptionIfNeeded(id)
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    logger.error("compose: redraft media not released: \(SciaLog.describe(error), privacy: .public)")
                    localMedia[id]?.failure = error
                    releaseTasks[id] = nil
                }
            }
        }
    }

    /// 予約していなければtrue。予約の日時が今から5分より後でなければ、知らせてfalseを返す。サーバーは過去の日時を断らずにすぐ投稿するため。
    private func acceptsSchedule() -> Bool {
        guard let scheduledAt, !ScheduledPosting.accepts(scheduledAt, now: now()) else { return true }
        logger.info("compose: schedule too soon")
        postError = ErrorPresentation(message: "予約の日時は今から5分より後にしてください。", code: nil)
        return false
    }

    /// 添付の準備を待つのをやめ、書ける状態に戻す。待っていなければ何もしない。サーバーに送り始めたあとは、取り消しても投稿されることがあるため。
    public func cancelWaitingForMedia() {
        guard isWaitingForMedia else { return }
        resumeMediaWait(.cancelled)
    }

    /// 添付の準備が済むか、失敗するか、待つのをやめるまで待つ。セッションを閉じて止められたときも、やめたものとする。
    private func waitForMedia() async -> MediaWaitOutcome {
        if let outcome = mediaWaitOutcome { return outcome }
        logger.info("compose: waiting for media before posting")
        isWaitingForMedia = true
        defer { isWaitingForMedia = false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { mediaWait = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeMediaWait(.cancelled) }
        }
    }

    /// 待つのを終えられる状態なら、その結果。まだ済んでいない添付があればnil。
    private var mediaWaitOutcome: MediaWaitOutcome? {
        let failed = attachments.contains { attachment in
            let status = attachmentStatus(of: attachment.id)
            return status == .failed || status == .descriptionFailed
        }
        if failed { return .failed }
        return areAttachmentsPrepared ? .ready : nil
    }

    /// 送る前に済ませる添付の準備が済んでいる。削除して書き直す元の投稿に付いている添付は、元の投稿を削除するまでは済んだものとし、
    /// 削除したあとは、元の投稿から外れて、書き換えた代替テキストを送るまで待つ。
    private var areAttachmentsPrepared: Bool {
        descriptionTasks.isEmpty && attachments.allSatisfy { attachment in
            attachment.isHeldByRedraftedStatus ? redraft?.deletion != .done : attachment.isReady
        }
    }

    /// 添付の状態が変わるたびに呼び、待っている投稿を終えられるなら続ける。
    private func settleMediaWait() {
        guard mediaWait != nil, let outcome = mediaWaitOutcome else { return }
        resumeMediaWait(outcome)
    }

    private func resumeMediaWait(_ outcome: MediaWaitOutcome) {
        guard let mediaWait else { return }
        self.mediaWait = nil
        mediaWait.resume(returning: outcome)
    }
}

/// 投稿ボタンを押したあとに、添付の準備を待った結果。
private enum MediaWaitOutcome {
    /// 全部済んだので送る。
    case ready
    /// 失敗した添付があるので送らない。
    case failed
    /// 待つのをやめた。
    case cancelled
}

// MARK: - メディアの添付

/// 添付したメディア1つの、端末の側だけで持つもの。
public struct LocalMedia<Thumbnail> {
    /// ピッカーの`assetIdentifier`。開き直したときに前の選択として渡す。ペーストしたものはピッカーで選んでいないのでnil。
    public let assetIdentifier: String?
    /// 読み込みを送り直すときに使う。前に選んだメディアはピッカーから読み直せないため、選んだときのものを持っておく。
    /// 引数のMIMEタイプの形式を避けて読み込む。
    public let load: @MainActor (_ avoiding: Set<String>) async throws -> LocalMediaFile
    /// 添付から外したときに呼ぶ。ペーストしたものは足す前から読み込んでいて、`file`に入る前に外すとファイルが残るため、それを消す。
    public var discardLoading: @MainActor () -> Void = {}
    /// 読み込んだファイル。読み込む前と、読み込みに失敗したときはnil。
    public var file: LocalMediaFile?
    public var thumbnail: Thumbnail?
    /// 失敗の理由。`DraftAttachment.State.failed`は理由を持たないため、ここに持つ。
    public var failure: (any Error)?
    /// 代替テキストを送れなかった理由。送れないと`needsDescriptionUpdate`のまま止まるため、送り直す操作と表示に使う。
    public var descriptionFailure: (any Error)?
    /// 送っている間の進み具合。0から1。
    public var progress: Double = 0
    /// 端末で書き出している間と書き出したあとの進み具合。0から1。書き出さないならnil。
    public var exportProgress: Double?
    /// 送るファイル。縮めるために作り直したら、そのファイル。作り直さないなら読み込んだファイル。決める前はnil。
    public var sending: LocalMediaFile?
    /// サーバーの上限のために縮めたときの前と後。
    public var reduction: MediaReduction?
    /// 送るファイルを、縮めるために作り直した。位置情報だけを除いて書き直したときは、元と同じ中身なのでfalse。切り抜いたときはtrue。
    public var sendingIsReencoded = false
    /// 送る前に切り抜く範囲。`file`は元のまま残し、送るファイルを作るときに当てる。切り抜かないならnil。
    public var crop: ImageCrop?
    /// 切り抜く範囲を変えた回数。切り抜いたファイルの名前に入れる。
    public var cropCount = 0
    /// 動画に音声がある。読み込んで調べる前と、動画でないときはnil。
    public var hasAudio: Bool?
    /// 動画の音声を除いて、GIFとして送る。Mastodonは音声のない動画をGIF（`gifv`）として扱うため。
    public var removesAudio = false
    /// GIFとして送るかを切り替えた回数。作り直したファイルの名前に入れる。
    /// 止めた前のアップロードがまだ書いていることがあり、同じ名前だと切り替えるたびに書き合うため。
    public var audioSwitchCount = 0

    public init(
        assetIdentifier: String?,
        load: @escaping @MainActor (_ avoiding: Set<String>) async throws -> LocalMediaFile,
        discardLoading: @escaping @MainActor () -> Void = {},
        file: LocalMediaFile? = nil,
        thumbnail: Thumbnail? = nil
    ) {
        self.assetIdentifier = assetIdentifier
        self.load = load
        self.discardLoading = discardLoading
        self.file = file
        self.thumbnail = thumbnail
    }

    /// GIFとして送るかと、切り替えた回数。
    public var audioChoice: AudioChoice {
        AudioChoice(removesAudio: removesAudio, switchCount: audioSwitchCount)
    }

    /// 投稿欄とビューアで見せる種類。GIFとして送る動画はGIFにする。読み込む前はnil。
    public var displayKind: MediaAttachment.Kind? {
        removesAudio ? .gifv : file?.kind
    }
}

/// 動画をGIFとして送るか（音声を除くか）と、切り替えた回数。切り替えた回数は、作り直したファイルの名前に入れる。
public struct AudioChoice {
    public var removesAudio = false
    public var switchCount = 0
}

/// 添付1つの、投稿欄とビューアで見せる状態。
public enum ComposeAttachmentStatus: Equatable {
    /// 送るために、端末で動画を書き出している。
    case exporting
    /// ファイルを読み込んで送っている。
    case uploading
    /// サーバーでの変換を待っている。
    case processing
    /// 投稿に付けられる。
    case ready
    /// 書いた代替テキストを送っている。
    case sendingDescription
    /// アップロードに失敗した。
    case failed
    /// 代替テキストを送れなかった。
    case descriptionFailed
}

/// 送る前に縮める大きさ（設定）と、作り直すときの好みの値（チューニング）。
public struct MediaPreparationSettings: Sendable {
    public var imageSize: ImageUploadSize
    public var videoSize: VideoUploadSize
    public var imageQuality: Double
    public var videoQuality: VideoPlan.Quality
    /// 書き出してから送るとき、進み具合の円のうち書き出しに割り振る割合。
    public var exportProgressShare: Double

    public init(imageSize: ImageUploadSize, videoSize: VideoUploadSize, imageQuality: Double, videoQuality: VideoPlan.Quality, exportProgressShare: Double) {
        self.imageSize = imageSize
        self.videoSize = videoSize
        self.imageQuality = imageQuality
        self.videoQuality = videoQuality
        self.exportProgressShare = exportProgressShare
    }

    /// 設定では縮めない。サーバーの上限を超えるものだけを縮める。メディアを添付しない画面とテストで使う。
    public static let keepsOriginal = MediaPreparationSettings(
        imageSize: .original,
        videoSize: .original,
        imageQuality: TuningCatalog.mediaImageQuality.defaultValue,
        videoQuality: VideoPlan.Quality(bitRate1080p: 8_000_000, minimumBitRate1080p: 1_000_000, sizeLimitMargin: 0.95, audioBitRate: 128_000),
        exportProgressShare: TuningCatalog.mediaExportProgressShare.defaultValue
    )
}

/// 投稿欄がメディアのアップロードに使うもの。
public struct ComposeMediaService<Thumbnail> {
    public var upload: (MediaUpload) async throws -> MediaAttachment
    public var waitUntilProcessed: (String) async throws -> MediaAttachment
    /// サーバーのIDと代替テキストを受け取り、`PUT /api/v1/media/:id`で送る。
    public var updateDescription: (String, String) async throws -> MediaAttachment
    public var makeThumbnail: (LocalMediaFile) async -> Thumbnail?
    /// 接続しているサーバーの今の版が処理できないと分かっている、画像の形式のMIMEタイプ。
    public var unprocessableImageTypes: @MainActor () -> Set<String>
    /// 画像の形式を、接続しているサーバーの今の版では処理できないと覚える。
    public var recordUnprocessableImageType: @MainActor (String) -> Void
    /// 送る前に縮める大きさと、作り直すときの好みの値。
    public var preparation: @MainActor () -> MediaPreparationSettings

    public init(
        upload: @escaping (MediaUpload) async throws -> MediaAttachment,
        waitUntilProcessed: @escaping (String) async throws -> MediaAttachment,
        updateDescription: @escaping (String, String) async throws -> MediaAttachment,
        makeThumbnail: @escaping (LocalMediaFile) async -> Thumbnail?,
        unprocessableImageTypes: @escaping @MainActor () -> Set<String>,
        recordUnprocessableImageType: @escaping @MainActor (String) -> Void,
        preparation: @escaping @MainActor () -> MediaPreparationSettings
    ) {
        self.upload = upload
        self.waitUntilProcessed = waitUntilProcessed
        self.updateDescription = updateDescription
        self.makeThumbnail = makeThumbnail
        self.unprocessableImageTypes = unprocessableImageTypes
        self.recordUnprocessableImageType = recordUnprocessableImageType
        self.preparation = preparation
    }

    /// メディアを添付しない画面とテストで使う。
    public static var unavailable: ComposeMediaService<Thumbnail> {
        ComposeMediaService(
            upload: { _ in throw CancellationError() },
            waitUntilProcessed: { _ in throw CancellationError() },
            updateDescription: { _, _ in throw CancellationError() },
            makeThumbnail: { _ in nil },
            unprocessableImageTypes: { [] },
            recordUnprocessableImageType: { _ in },
            preparation: { .keepsOriginal }
        )
    }
}

extension ComposeModel {
    /// ピッカーに前の選択として渡すID。添付の並び順。
    public var attachedAssetIdentifiers: [String] {
        attachments.compactMap { localMedia[$0.id]?.assetIdentifier }
    }

    /// ピッカーで選べる枚数。編集している投稿に付いている添付とペーストした添付は、ピッカーの選択に入らないため、その分を除く。
    public var pickerSelectionLimit: Int {
        max(maxMediaAttachments - attachments.filter { localMedia[$0.id]?.assetIdentifier == nil }.count, 0)
    }

    /// ピッカーの今の選択を取り込む。外されたものは添付から外し、足されたものは後ろに足してアップロードを始める。
    /// 投稿を待つ間も取り込む。ピッカーは選択が変わったことを覚えるので、捨てると投稿に失敗した後の下書きとピッカーの選択が食い違う。
    /// 送っている下書きは送る前にコピーしてあるので、ここで変えても影響しない。
    /// 添付の準備を待っている間に選択が変わったら、待つのをやめる。待ったあとに作る下書きが、押した時点と違う添付になるため。
    /// 押したときにシートは閉じるが、閉じ終わる前に選び直しが届くことがある。
    public func applyPickerSelection(_ selection: [PickedMedia]) {
        let changes = pickerSelection.changes(current: attachedAssetIdentifiers, selected: selection.map(\.assetIdentifier))
        if isWaitingForMedia, !changes.removed.isEmpty || !changes.added.isEmpty {
            logger.info("compose: picker selection changed while waiting for media")
            resumeMediaWait(.cancelled)
        }
        let removed = Set(changes.removed)
        for attachment in attachments where localMedia[attachment.id]?.assetIdentifier.map(removed.contains) ?? false {
            discardAttachment(attachment.id)
        }
        let added = Set(changes.added)
        // Mastodonのweb UIと同じく、既定で閲覧注意にする人は、最初の添付を足したときに注意書きの欄を開く。開いた欄で閲覧注意が付いたと分かる。
        if attachments.isEmpty, defaultSensitive, selection.contains(where: { added.contains($0.assetIdentifier) }) {
            showsSpoiler = true
        }
        for picked in selection where added.contains(picked.assetIdentifier) {
            let attachment = DraftAttachment()
            attachments.append(attachment)
            localMedia[attachment.id] = LocalMedia(assetIdentifier: picked.assetIdentifier, load: picked.load)
            startUpload(attachment.id)
        }
    }

    /// ペーストしたメディアを後ろに足し、アップロードを始める。上限を超えた分は足さずに知らせる。
    /// 入る分だけ足すのは、全部を断るより、入りきらない分を選び直すほうが手間が少ないため。
    public func addPastedMedia(_ pasted: [PastedMedia]) {
        let room = max(maxMediaAttachments - attachments.count, 0)
        let added = pasted.prefix(room)
        if attachments.isEmpty, defaultSensitive, !added.isEmpty {
            showsSpoiler = true
        }
        for media in added {
            let load = media.load
            let attachment = DraftAttachment()
            attachments.append(attachment)
            var local = LocalMedia<Thumbnail>(assetIdentifier: nil) { _ in try await load() }
            local.discardLoading = media.discard
            localMedia[attachment.id] = local
            startUpload(attachment.id)
        }
        let skipped = pasted.dropFirst(room)
        guard !skipped.isEmpty else { return }
        for media in skipped {
            media.discard()
        }
        logger.info("pasted media skipped over the limit (added=\(added.count) skipped=\(skipped.count))")
        onPastedMediaSkipped(skipped.map(\.kind))
    }

    /// ピッカーを閉じた。
    public func mediaPickerDidClose() {
        pickerSelection.pickerDidClose()
    }

    /// 投稿欄から添付を外す。ピッカーを開いていれば、ピッカーがまだ選んだままの選択を送ってきても足し直さない。
    /// 編集している投稿に付いている添付とペーストした添付は、ピッカーで選んだものではないため、そのまま外す。
    /// 送っている間と、準備を待っている間は外さない。送る中身は押した時点で決めるため。
    public func removeAttachment(_ id: DraftAttachment.ID, pickerIsOpen: Bool) {
        guard !isPosting, attachments.contains(where: { $0.id == id }) else { return }
        if let assetIdentifier = localMedia[id]?.assetIdentifier {
            pickerSelection.didRemoveInDraft(assetIdentifier, pickerIsOpen: pickerIsOpen)
        }
        discardAttachment(id)
    }

    /// 失敗した添付を送り直す。処理の待ち時間切れなら、サーバーに残っている同じIDで待ち直す。
    /// 代替テキストだけを送れなかったなら、代替テキストだけを送り直す。
    public func retryAttachment(_ id: DraftAttachment.ID) {
        guard let attachment = attachments.first(where: { $0.id == id }) else { return }
        // 削除した元の投稿から外れるのを待ちきれなかった添付は、待ち直す。
        if attachment.isHeldByRedraftedStatus {
            startReleasingRedraftMedia()
            return
        }
        switch attachment.state {
        case .failed:
            startUpload(id)
        case .uploaded:
            localMedia[id]?.descriptionFailure = nil
            sendDescriptionIfNeeded(id)
        case .uploading, .processing:
            return
        }
    }

    /// 動画をGIFとして送るか（音声を除くか）を切り替え、送り直す。送り終えていても、サーバーの添付は使わずに送り直す。
    /// 音声のない動画は、もとからGIFとして扱われるので切り替えない。
    public func setRemovesAudio(_ removesAudio: Bool, of id: DraftAttachment.ID) {
        guard !isPosting, let local = localMedia[id], local.hasAudio == true, local.removesAudio != removesAudio else { return }
        logger.info("attachment removesAudio=\(removesAudio, privacy: .public)")
        localMedia[id]?.removesAudio = removesAudio
        localMedia[id]?.audioSwitchCount += 1
        uploadTasks.removeValue(forKey: id)?.cancel()
        descriptionTasks.removeValue(forKey: id)?.cancel()
        // 作り直したファイルは、読み込んだファイルと同じディレクトリにあるので、添付を外せば一緒に消える。ここでは消さない。
        // 止めたアップロードが、まだ読んでいることがあるため。
        localMedia[id]?.sending = nil
        localMedia[id]?.reduction = nil
        localMedia[id]?.sendingIsReencoded = false
        localMedia[id]?.exportProgress = nil
        localMedia[id]?.progress = 0
        localMedia[id]?.failure = nil
        localMedia[id]?.descriptionFailure = nil
        setState(.uploading, of: id)
        startUpload(id)
    }

    /// 代替テキストを書き換える。アップロードが済んでいればすぐ送り、済む前ならアップロードと一緒に（間に合わなければ済んでから）送る。
    public func setDescription(_ description: String, of id: DraftAttachment.ID) {
        guard !isPosting, let index = attachments.firstIndex(where: { $0.id == id }), attachments[index].description != description else { return }
        attachments[index].description = description
        localMedia[id]?.descriptionFailure = nil
        sendDescriptionIfNeeded(id)
    }

    /// 切り抜ける添付。読み込み終えた画像で、編集している投稿にもう付いていないもの。GIFは動きを保ったまま切り抜けないので除く。
    /// 送っている間と、準備を待っている間は切り抜かない。
    public func canCrop(_ id: DraftAttachment.ID) -> Bool {
        guard !isPosting, let attachment = attachments.first(where: { $0.id == id }), !attachment.isAttachedToStatus,
              let file = localMedia[id]?.file
        else { return false }
        return file.kind == .image && file.mimeType != "image/gif"
    }

    /// 切り抜く範囲を変え、アップロードし直す。Mastodonには、アップロード済みのメディアのファイルを差し替えるAPIがないため。
    /// 前のアップロードと代替テキストの送信は止め、前のメディアはどの投稿にも付かないまま残す。代替テキストはアップロードし直すときに一緒に送る。
    /// - Parameters:
    ///   - crop: 切り抜く範囲。切り抜かずに元のまま送るならnil。
    ///   - preview: 切り抜いた画像。送るファイルを作り終えるまで、投稿欄のサムネイルとビューアに出す。
    public func setCrop(_ crop: ImageCrop?, preview: Thumbnail?, of id: DraftAttachment.ID) {
        guard canCrop(id), let local = localMedia[id], let file = local.file, let size = ImageReencoder.size(of: file.url),
              !ImageCrop.selectsSamePixels(local.crop, crop, in: size)
        else { return }
        // 全体を残す範囲は、切り抜かないのと同じなので、元のまま送る。
        let crop = crop.flatMap { $0.isIdentity(in: size) ? nil : $0 }
        logger.info("attachment crop changed turns=\(crop?.quarterTurns ?? 0, privacy: .public) rect=\(String(describing: crop?.rect), privacy: .public)")
        uploadTasks.removeValue(forKey: id)?.cancel()
        thumbnailTasks.removeValue(forKey: id)?.cancel()
        descriptionTasks.removeValue(forKey: id)?.cancel()
        // 作り直したファイルは、読み込んだファイルと同じディレクトリにあるので、添付を外せば一緒に消える。ここでは消さない。
        // 止めたアップロードが、まだ読んでいることがあるため。
        localMedia[id]?.crop = crop
        localMedia[id]?.cropCount += 1
        localMedia[id]?.sending = nil
        localMedia[id]?.reduction = nil
        localMedia[id]?.sendingIsReencoded = false
        localMedia[id]?.failure = nil
        localMedia[id]?.descriptionFailure = nil
        localMedia[id]?.progress = 0
        localMedia[id]?.exportProgress = nil
        if let preview {
            localMedia[id]?.thumbnail = preview
        }
        setState(.uploading, of: id)
        startUpload(id)
    }

    /// 添付を`index`の位置へ移す。投稿の`media_ids[]`はこの順になる。
    public func moveAttachment(_ id: DraftAttachment.ID, to index: Int) {
        guard !isPosting, let from = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments.remove(at: from)
        attachments.insert(attachment, at: min(max(index, 0), attachments.count))
    }

    /// 書き出しと送信の進み具合を1つにまとめた値。0から1。どちらもしていなければnil。
    /// 書き出すときは、円の前半を書き出し、後半を送信に割り振る。段階ごとに円を出し直すと、満ちた円がまた0から始まって見えるため。
    public func attachmentProgress(of id: DraftAttachment.ID) -> Double? {
        guard let status = attachmentStatus(of: id), status == .exporting || status == .uploading, let local = localMedia[id] else { return nil }
        guard let export = local.exportProgress else { return local.progress }
        let share = media.preparation().exportProgressShare
        return share * export + (1 - share) * (status == .exporting ? 0 : local.progress)
    }

    /// 投稿欄とビューアで見せる状態。
    public func attachmentStatus(of id: DraftAttachment.ID) -> ComposeAttachmentStatus? {
        guard let attachment = attachments.first(where: { $0.id == id }) else { return nil }
        switch attachment.state {
        case .uploading:
            if let export = localMedia[id]?.exportProgress, export < 1, localMedia[id]?.sending == nil { return .exporting }
            return .uploading
        case .processing: return .processing
        case .failed: return .failed
        case .uploaded:
            if attachment.isHeldByRedraftedStatus {
                if releaseTasks[id] != nil { return .processing }
                return localMedia[id]?.failure == nil ? .ready : .failed
            }
            if descriptionTasks[id] != nil { return .sendingDescription }
            guard attachment.needsDescriptionUpdate else { return .ready }
            return localMedia[id]?.descriptionFailure == nil ? .sendingDescription : .descriptionFailed
        }
    }

    private func discardAttachment(_ id: DraftAttachment.ID) {
        uploadTasks.removeValue(forKey: id)?.cancel()
        releaseTasks.removeValue(forKey: id)?.cancel()
        thumbnailTasks.removeValue(forKey: id)?.cancel()
        descriptionTasks.removeValue(forKey: id)?.cancel()
        if let local = localMedia.removeValue(forKey: id) {
            local.file?.remove()
            local.discardLoading()
            // 作り直したファイルは、読み込んだファイルと同じディレクトリに置くので、上で一緒に消える。
            if let sending = local.sending, sending.url.deletingLastPathComponent() != local.file?.url.deletingLastPathComponent() {
                sending.remove()
            }
        }
        attachments.removeAll { $0.id == id }
    }

    public func removeAllAttachments() {
        for attachment in attachments {
            discardAttachment(attachment.id)
        }
        pickerSelection = MediaPickerSelection()
    }

    private func setState(_ state: DraftAttachment.State, of id: DraftAttachment.ID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = state
    }

    private func startUpload(_ id: DraftAttachment.ID) {
        uploadTasks[id]?.cancel()
        uploadTasks[id] = tasks.run(.action) { [weak self] in await self?.upload(id) }
    }

    /// ファイルを読み込み、アップロードし、サーバーでの変換が済むまで待つ。途中で添付から外されたら、何も書き戻さない。
    private func upload(_ id: DraftAttachment.ID) async {
        guard let local = localMedia[id], attachments.contains(where: { $0.id == id }) else { return }
        let endBackgroundTime = backgroundTime("upload attachment")
        defer { endBackgroundTime() }
        // 投稿するアカウントを替えたら、送る前と応答を受けたところで抜ける。送り直しは`startAwaitingReuploads`が、この処理が抜けるのを待って始める。
        let generation = accountGeneration
        let isStale = { [unowned self] in generation != accountGeneration }
        localMedia[id]?.failure = nil
        localMedia[id]?.descriptionFailure = nil
        var sentDescription: String?
        do {
            let processed: MediaAttachment
            setState(.uploading, of: id)
            let file = try await loadFile(id, local: local)
            // GIFとして送るかは、始めた時点の値で決める。待っている間に切り替わると、止めたこの処理が新しい処理と同じファイルに書くため。
            let sending = try await prepare(file, of: id, audio: local.audioChoice)
            guard !isStale() else { return }
            let accepted: MediaAttachment
            do {
                accepted = try await send(sending, of: id, sentDescription: &sentDescription)
            } catch let error where UnprocessableMediaFormats.shouldReplaceWithJPEG(mimeType: sending.mimeType, error: error) {
                // 切り抜き直して止めたアップロードには、止める前に届いたエラーがそのまま返る。送り直すと元のファイルを消すので、先に止まったかを確かめる。
                try Task.checkCancellation()
                // 対応形式として返しているのに処理できないサーバーがある（Mastodon 4.7.2と4.7.3のHEICなど）。
                // 同じ写真のJPEGで1回だけ送り直し、このサーバーのこの版ではその形式を送らないと覚える。
                logger.info("attachment format unprocessable, resending as jpeg mime=\(sending.mimeType, privacy: .public) reencoded=\(sending != file, privacy: .public)")
                media.recordUnprocessableImageType(sending.mimeType)
                let replacement: LocalMediaFile
                if localMedia[id]?.sendingIsReencoded == true {
                    // 縮めるために作り直したファイルなら、元から作り直す。JPEGに決めて作り直す。
                    try? FileManager.default.removeItem(at: sending.url)
                    localMedia[id]?.sending = nil
                    replacement = try await prepare(file, of: id, forcingJPEG: true)
                } else if local.assetIdentifier == nil {
                    // ペーストしたものは、クリップボードの中身が変わっているかもしれず読み直せないので、読み込んだファイルからJPEGを作る。
                    // 位置情報だけを除いて書き直したファイルは、作り直すファイルと同じ場所を使うので、先に消す。
                    if sending != file {
                        try? FileManager.default.removeItem(at: sending.url)
                    }
                    localMedia[id]?.sending = nil
                    replacement = try await prepare(file, of: id, forcingJPEG: true)
                } else {
                    // 元のまま、または位置情報だけを除いて送ったファイルなら、ピッカーから同じ写真のJPEGを受け取り直す。
                    replacement = try await prepare(try await reloadFile(id, local: local, avoiding: file), of: id, forcingJPEG: true)
                }
                accepted = try await send(replacement, of: id, sentDescription: &sentDescription)
            }
            try Task.checkCancellation()
            guard !isStale() else { return }
            if accepted.url == nil {
                setState(.processing(serverID: accepted.id), of: id)
                processed = try await media.waitUntilProcessed(accepted.id)
            } else {
                processed = accepted
            }
            try Task.checkCancellation()
            guard !isStale() else { return }
            setState(.uploaded(processed), of: id)
            if let sentDescription {
                acceptServerDescription(of: id, sent: sentDescription, returned: processed)
            }
            sendDescriptionIfNeeded(id)
        } catch {
            guard !Task.isCancelled, localMedia[id] != nil, !isStale() else { return }
            logger.info("attachment upload failed error=\(SciaLog.describe(error), privacy: .public)")
            localMedia[id]?.failure = error
            setState(.failed(serverID: attachments.first { $0.id == id }?.serverID), of: id)
        }
    }

    /// ファイルを送る。読み込む間に書いた代替テキストも一緒に送れるよう、送る直前の値を読み、送った値を`sentDescription`に入れる。
    private func send(_ file: LocalMediaFile, of id: DraftAttachment.ID, sentDescription: inout String?) async throws -> MediaAttachment {
        let description = attachments.first { $0.id == id }?.description ?? ""
        sentDescription = description
        localMedia[id]?.progress = 0
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.setProgress(fraction, of: id) }
        }
        let upload = try await file.upload(description: description)
        return try await UploadProgress.$report.withValue(report) {
            try await media.upload(upload)
        }
    }

    /// 送った割合を進み具合にする。URLSessionは細かく知らせてくるので、見た目の変わらない差では描き直さない。
    /// 知らせはメインスレッドへ順に回すとは限らないので、戻る向きには動かさない。
    private func setProgress(_ fraction: Double, of id: DraftAttachment.ID) {
        guard let current = localMedia[id]?.progress, fraction - current >= 0.01 || (fraction >= 1 && current < 1) else { return }
        localMedia[id]?.progress = fraction
    }

    /// 送るファイルを決める。設定で選んだ大きさとサーバーの上限に収まれば、読み込んだファイルのまま送る。位置情報があれば、それだけを除いたファイルにする。
    /// 収まらなければ作り直し、サーバーの上限のために設定より小さくしたら知らせる。送り直すときは、前に決めたファイルを使う。
    /// - Parameter forcingJPEG: JPEGで送り直すので、縮めて作り直すときもHEICなどにしない。覚えたのは処理できなかった形式（HEIFなど）だけで、
    ///   HEICは覚えていないことがあり、同じサーバーがHEICも処理できないことが多いため。
    /// - Parameter audio: 動画をGIFとして送るかと、切り替えた回数。
    private func prepare(_ file: LocalMediaFile, of id: DraftAttachment.ID, audio: AudioChoice = AudioChoice(), forcingJPEG: Bool = false) async throws -> LocalMediaFile {
        if let sending = localMedia[id]?.sending { return sending }
        let settings = media.preparation()
        let byteCount = ImageReencoder.byteCount(of: file.url)
        let prepared: PreparedMedia?
        var reencoded = false
        switch file.kind {
        case .image:
            guard let originalSize = ImageReencoder.size(of: file.url) else { throw MediaReencodingError.imageFailed }
            let crop = localMedia[id]?.crop
            // 切り抜くなら、切り抜いた大きさに設定とサーバーの上限を当てはめ、縮めるのと1回で作り直す。
            let size = crop?.outputSize(of: originalSize) ?? originalSize
            let plan = ImagePlan.make(
                size: size, byteCount: byteCount, mimeType: file.mimeType, setting: settings.imageSize, limits: mediaLimits,
                supportedMIMETypes: supportedMediaTypes,
                unprocessableMIMETypes: media.unprocessableImageTypes().union(forcingJPEG ? UnprocessableMediaFormats.replaceableMIMETypes : []),
                cropping: crop != nil
            )
            reencoded = plan != nil
            prepared = if let plan {
                try await ImageReencoder.reencode(
                    file.url, plan: plan, crop: crop, originalSize: size, sizeLimit: mediaLimits.imageSizeLimit, quality: settings.imageQuality,
                    destination: Self.preparedURL(for: file, cropCount: crop != nil ? localMedia[id]?.cropCount : nil)
                )
            } else {
                try await LocationRemover.removingLocation(fromImage: file.url, destination: Self.preparedURL(for: file))
                    .map { PreparedMedia(url: $0, mimeType: file.mimeType, size: size, reduction: nil) }
            }
        case .video:
            (prepared, reencoded) = try await prepareVideo(file, of: id, audio: audio, byteCount: byteCount, settings: settings)
        case .gifv, .audio, .unknown:
            prepared = nil
        }
        try Task.checkCancellation()
        guard localMedia[id] != nil else {
            if let prepared { try? FileManager.default.removeItem(at: prepared.url) }
            throw CancellationError()
        }
        let sending = prepared.map { LocalMediaFile(url: $0.url, mimeType: $0.mimeType, kind: file.kind) } ?? file
        localMedia[id]?.sending = sending
        localMedia[id]?.reduction = prepared?.reduction
        localMedia[id]?.sendingIsReencoded = reencoded
        if let prepared {
            logger.info("attachment prepared kind=\(String(describing: file.kind), privacy: .public) mime=\(prepared.mimeType, privacy: .public) size=\(prepared.size.description, privacy: .public) reducedByServer=\(prepared.reduction != nil, privacy: .public)")
        }
        if prepared?.reduction != nil {
            onMediaReduced(file.kind)
        }
        return sending
    }

    /// 動画を、設定で選んだ大きさとサーバーの上限に収まるよう書き出す。収まっていれば、位置情報があるときだけ除いて書き直す。どちらもしなければnil。
    /// - Returns: 書き出したか書き直したファイルと、縮めるために書き出したか。
    private func prepareVideo(
        _ file: LocalMediaFile,
        of id: DraftAttachment.ID,
        audio: AudioChoice,
        byteCount: Int,
        settings: MediaPreparationSettings
    ) async throws -> (PreparedMedia?, reencoded: Bool) {
        guard let info = await VideoReencoder.info(of: file.url) else { throw MediaReencodingError.videoFailed }
        localMedia[id]?.hasAudio = info.hasAudio
        let removesAudio = info.hasAudio && audio.removesAudio
        let preparedURL = Self.preparedURL(for: file, audioSwitchCount: audio.switchCount > 0 ? audio.switchCount : nil)
        let plan = VideoPlan.make(
            size: info.size, duration: info.duration, frameRate: info.frameRate, hasAudio: info.hasAudio && !removesAudio, byteCount: byteCount,
            setting: settings.videoSize, limits: mediaLimits, quality: settings.videoQuality
        )
        switch plan {
        case .original where removesAudio:
            // 組み直すとメタデータは付いてこないので、位置情報も一緒に除かれる。
            let destination = preparedURL
            try await AudioRemover.removingAudio(fromVideo: file.url, destination: destination)
            return (PreparedMedia(url: destination, mimeType: file.mimeType, size: info.size, reduction: nil), false)
        case .original:
            // 書き出す動画には位置情報を書かないので、元のまま送るときだけ除く。
            let cleaned = try await LocationRemover.removingLocation(fromVideo: file.url, destination: preparedURL)
            return (cleaned.map { PreparedMedia(url: $0, mimeType: file.mimeType, size: info.size, reduction: nil) }, false)
        case .tooLong:
            throw MediaReencodingError.videoTooLong
        case .export(let size, let frameRate, let bitRate, let reducedByServer):
            localMedia[id]?.exportProgress = 0
            let destination = preparedURL.deletingPathExtension().appendingPathExtension("mp4")
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in self?.setExportProgress(fraction, of: id) }
            }
            try await VideoReencoder.export(
                file.url, size: size, frameRate: frameRate, bitRate: bitRate, audioBitRate: settings.videoQuality.audioBitRate,
                removesAudio: removesAudio, destination: destination, progress: report
            )
            let exportedByteCount = ImageReencoder.byteCount(of: destination)
            if let limit = mediaLimits.videoSizeLimit, exportedByteCount > limit {
                try? FileManager.default.removeItem(at: destination)
                throw MediaReencodingError.cannotFitSizeLimit
            }
            let reduction = reducedByServer ? MediaReduction(fromSize: info.size, toSize: size, fromByteCount: byteCount, toByteCount: exportedByteCount) : nil
            return (PreparedMedia(url: destination, mimeType: "video/mp4", size: size, reduction: reduction), true)
        }
    }

    /// 作り直したファイルの置き場所。読み込んだファイルと同じディレクトリに、名前を変えて置く。
    /// 切り抜いたファイルは、切り抜くたびに名前を変える。切り抜き直して止めたアップロードが、同じファイルに書き続けていることがあるため。
    /// - Parameters:
    ///   - cropCount: 切り抜くなら、切り抜く範囲を変えた回数。
    ///   - audioSwitchCount: GIFとして送るかを切り替えた動画なら、切り替えた回数。
    private static func preparedURL(for file: LocalMediaFile, cropCount: Int? = nil, audioSwitchCount: Int? = nil) -> URL {
        let prefix = cropCount.map { "cropped-\($0)-" } ?? audioSwitchCount.map { "audio-\($0)-" } ?? "prepared-"
        return file.url.deletingLastPathComponent().appending(fileName: SafeFileName(prefix + file.url.lastPathComponent))
    }

    /// 書き出した割合を進み具合にする。送った割合と同じく、見た目の変わらない差では描き直さず、戻る向きには動かさない。
    private func setExportProgress(_ fraction: Double, of id: DraftAttachment.ID) {
        guard let current = localMedia[id]?.exportProgress, fraction - current >= 0.01 || (fraction >= 1 && current < 1) else { return }
        localMedia[id]?.exportProgress = fraction
    }

    /// サーバーが処理できなかったファイルを捨て、その形式を避けて読み込み直す。サムネイルは同じ写真なので作り直さない。
    private func reloadFile(_ id: DraftAttachment.ID, local: LocalMedia<Thumbnail>, avoiding rejected: LocalMediaFile) async throws -> LocalMediaFile {
        rejected.remove()
        localMedia[id]?.file = nil
        localMedia[id]?.sending = nil
        let file = try await local.load(media.unprocessableImageTypes().union([rejected.mimeType]))
        guard localMedia[id] != nil, !Task.isCancelled else {
            file.remove()
            throw CancellationError()
        }
        localMedia[id]?.file = file
        return file
    }

    /// 読み込み済みならそのファイルを使う。初めて読み込んだら、サムネイルも作り始める。
    private func loadFile(_ id: DraftAttachment.ID, local: LocalMedia<Thumbnail>) async throws -> LocalMediaFile {
        if let file = local.file { return file }
        let file = try await local.load(media.unprocessableImageTypes())
        guard localMedia[id] != nil, !Task.isCancelled else {
            file.remove()
            throw CancellationError()
        }
        localMedia[id]?.file = file
        thumbnailTasks[id] = tasks.run(.action) { [weak self, media] in
            let thumbnail = await media.makeThumbnail(file)
            guard !Task.isCancelled else { return }
            self?.localMedia[id]?.thumbnail = thumbnail
        }
        return file
    }

    /// 書いた代替テキストがサーバーの値と違えば送る。送っている間に書き直されたら、送り終えてから書き直した値を送る。
    private func sendDescriptionIfNeeded(_ id: DraftAttachment.ID) {
        guard descriptionTasks[id] == nil, localMedia[id]?.descriptionFailure == nil,
              let attachment = attachments.first(where: { $0.id == id }), attachment.needsDescriptionUpdate,
              let serverID = attachment.serverID
        else { return }
        let description = attachment.description
        descriptionTasks[id] = tasks.run(.action) { [weak self, media] in
            do {
                let updated = try await media.updateDescription(serverID, description)
                guard let self, !Task.isCancelled else { return }
                // 応答を反映してから送り終えたことにする。先に外すと、投稿を待つ側が、書き戻した値と前のサーバーの値が同じなのを見て、送り直す前に済んだと判断するため。
                self.setState(.uploaded(updated), of: id)
                self.acceptServerDescription(of: id, sent: description, returned: updated)
                self.descriptionTasks[id] = nil
                self.sendDescriptionIfNeeded(id)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.descriptionTasks[id] = nil
                self.localMedia[id]?.descriptionFailure = error
            }
        }
    }

    /// 送ったあと書き直していなければ、サーバーが返した代替テキストを下書きの値にする。
    /// 前後の空白を除くなど、サーバーが整えて返す実装でも、送った値との違いで送り続けないようにする（Mastodonは整えない）。
    private func acceptServerDescription(of id: DraftAttachment.ID, sent: String, returned: MediaAttachment) {
        guard let index = attachments.firstIndex(where: { $0.id == id }), attachments[index].description == sent else { return }
        attachments[index].description = returned.description ?? ""
    }
}
