import Foundation
import Observation
import os
import SciaCore
import UIKit

/// 投稿欄の下書きの状態。
@MainActor
@Observable
final class ComposeModel {
    var text: String
    var spoilerText: String
    /// 注意書きの欄を出している。隠しているときは注意書きなしで投稿する。
    /// 出していれば、注意書きが空でも、添付を閲覧注意にする。
    var showsSpoiler: Bool
    private(set) var visibility: Status.Visibility
    /// 返信先。新しい投稿と、編集ならnil。
    private(set) var replyTo: Status?
    /// 引用する投稿。引用しなければnil。返信先とは一緒に付けない。決まりはdocs/quote.mdの「引用して投稿する」にある。
    private(set) var quoteTarget: Status?
    /// 編集している自分の投稿。編集でなければnil。公開範囲と返信先は変えられない。
    private(set) var editedStatus: Status?
    private(set) var maxCharacters = 500
    private(set) var charactersReservedPerURL = 23
    private(set) var maxMediaAttachments = 4
    /// 代替テキストの文字数の上限。
    private(set) var mediaDescriptionLimit = 1500
    /// サーバーが受け付けるメディアの大きさの上限。読めるまでは分からないものとして、縮めない。
    @ObservationIgnored private var mediaLimits = MediaLimits.unknown
    /// サーバーが受け付けると返した形式。返さないサーバーではnil。
    @ObservationIgnored private var supportedMediaTypes: [String]?
    private(set) var isPosting = false
    var errorMessage: String?
    /// 添付したメディア。この順で投稿に並ぶ。
    private(set) var attachments: [DraftAttachment] = []
    /// 付ける投票。投票の欄を出していなければnil。添付とは一緒に付けられないため、添付があるときは足せない。
    var poll: PollDraft?
    /// サーバーが受け付ける投票の上限。読めるまではMastodonの既定値にする。
    private(set) var pollLimits = PollLimits.mastodonDefault
    /// 添付したメディアごとの、端末の側だけで持つもの。
    private(set) var localMedia: [DraftAttachment.ID: LocalMedia] = [:]
    /// 予約する日時。予約の行を出していなければnil。決まりはdocs/compose.mdの「予約投稿」にある。
    private(set) var scheduledAt: Date?
    /// 書き直している予約。送れたら`onScheduleRewritten`で取り消させる。決まりはdocs/compose.mdの「書き直す」にある。
    private(set) var rewritingSchedule: ScheduledStatus?
    /// 投稿の言語のコード。nilなら送らず、サーバーに任せる。決まりはdocs/compose.mdの「投稿の言語」にある。
    private(set) var language: String?
    /// アカウントの既定の言語。決めていないか、まだ読めていなければnil。
    private(set) var defaultLanguage: String?

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
    /// 最後に送った内容。同じ内容を送り直すときだけ同じIdempotency-Keyを使い、変えたら別の投稿として新しいキーにする。
    /// 応答だけが失われていた場合に、変えた内容が投稿されないまま成功扱いにならないようにするため。
    @ObservationIgnored private var lastSubmitted: StatusDraft?
    @ObservationIgnored let myAccountID: String
    /// 予約の日時を決める今の日付。テストでは決まった日付に差し替える。
    @ObservationIgnored var now: () -> Date = AppDependencies.now
    /// 予約の日時を区切る暦。テストでは決まったタイムゾーンの暦に差し替える。
    @ObservationIgnored var calendar = Calendar.autoupdatingCurrent
    @ObservationIgnored private let post: (StatusDraft) async throws -> Void
    @ObservationIgnored private let media: ComposeMediaService
    /// 下書きの送信とアップロードの持ち主。セッションの持ち主の子で、ログアウトやアカウントの切り替えで閉じると、送っている途中のものも止める。
    @ObservationIgnored let tasks: TaskScope
    /// 送っている途中にバックグラウンドへ移っても、送り終えるまでアプリを止めないよう頼む。終えるときに呼ぶものを返す。
    @ObservationIgnored private let backgroundTime: @MainActor (String) -> @MainActor () -> Void
    @ObservationIgnored private var uploadTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    /// 代替テキストを送っている添付。送っている間は、書き戻してサーバーの値と同じになっても、送り終えるまで投稿させない。
    /// 送り終えた後のサーバーの値が、書き戻した値と違うことがあるため。投稿の可否が変わるので、変更を見張れるようにする。
    private var descriptionTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pickerSelection = MediaPickerSelection()
    @ObservationIgnored private let logger = SciaLog.logger(category: "compose")
    /// 投稿できて、下書きを空に戻したあとに呼ぶ。
    @ObservationIgnored var onPosted: () -> Void = {}
    /// 予約を書き直した投稿を送れて、`onPosted`を呼んだあとに、元の予約のIDを渡して呼ぶ。元の予約を取り消すのは呼ぶ側。
    @ObservationIgnored var onScheduleRewritten: (ScheduledStatus.ID) -> Void = { _ in }
    /// サーバーの上限のために、設定で選んだより小さく、または低い画質にした。使う人が選んでいない画質の変化なので、知らせる。
    @ObservationIgnored var onMediaReduced: (MediaAttachment.Kind) -> Void = { _ in }
    /// ペーストしたメディアのうち、添付の上限を超えて足さなかったものの種類。
    @ObservationIgnored var onPastedMediaSkipped: ([MediaAttachment.Kind]) -> Void = { _ in }

    init(
        tasks: TaskScope,
        replyTo: Status? = nil,
        myAccountID: String,
        media: ComposeMediaService = .unavailable,
        backgroundTime: @escaping @MainActor (String) -> @MainActor () -> Void = BackgroundTime.request,
        post: @escaping (StatusDraft) async throws -> Void
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
        self.myAccountID = myAccountID
        self.post = post
        self.media = media
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
    var choosesNonDefaultLanguage: Bool {
        language != nil && language != defaultLanguage
    }

    /// 言語を選ぶ。nilなら送らずにサーバーに任せる。
    func choose(language: String?) {
        guard !isPosting else { return }
        self.language = language
        hasChosenLanguage = true
    }

    /// 添付を閲覧注意にして投稿する。
    var isSensitive: Bool {
        draftToPost.sensitive
    }

    var remainingCharacters: Int {
        maxCharacters - draftToPost.length(charactersReservedPerURL: charactersReservedPerURL)
    }

    var canPost: Bool {
        !isPosting && descriptionTasks.isEmpty && (hasResolvedDefaults || hasChosenVisibility || editedStatus != nil) && draftToPost.canPost(maxCharacters: maxCharacters, charactersReservedPerURL: charactersReservedPerURL, maxMediaAttachments: maxMediaAttachments, pollLimits: pollLimits)
    }

    /// メディアを選べる。枚数の上限をサーバーの値で読むまでは、ピッカーを開かない。
    /// 読めなかったときは、次に書き始めたときに読み直す。
    /// 編集している投稿の添付で上限まで埋まっていても開かない。ピッカーの上限の0は、選べないではなく上限なしを意味するため。
    /// 投票の欄を出している間と、引用している間も開かない。Mastodonは投票や引用と添付を一緒に付けられないため。
    var canAttachMedia: Bool {
        !isPosting && hasLoadedConfiguration && pickerSelectionLimit > 0 && poll == nil && !isQuoting
    }

    /// メディアをペーストできる。ピッカーと違い、上限まで埋まっていても受け付け、入りきらない分を知らせる。
    /// 投票の欄を出している間と、引用している間は受け付けない。
    var canPasteMedia: Bool {
        !isPosting && hasLoadedConfiguration && poll == nil && !isQuoting
    }

    /// 投票の欄を足せる。添付があるときと引用しているときは、Mastodonが一緒に付けられないため足せない。
    /// 編集では足せない。投票の付いた投稿の編集は、元の投票をそのまま送り直す。決まりはdocs/compose.mdの「自分の投稿の編集」にある。
    var canAddPoll: Bool {
        !isPosting && attachments.isEmpty && editedStatus == nil && !isQuoting
    }

    /// 引用している。書き直している予約の引用は、引用元の投稿を持たずIDだけを持つ。
    var isQuoting: Bool {
        quoteTarget != nil || initialDraft.quotedStatusID != nil
    }

    /// 返信している。書き直している予約の返信は、返信先の投稿を持たずIDだけを持つ。
    var isReplying: Bool {
        replyTo != nil || initialDraft.inReplyToID != nil
    }

    /// 予約の行を足せる。Mastodonは編集の予約を受け付けないため、編集では足せない。
    var canSchedule: Bool {
        !isPosting && editedStatus == nil
    }

    /// 予約の行を出す。日時は1時間より先の、いちばん近い正時にする。足せないときは何もしない。
    func addSchedule() {
        guard scheduledAt == nil, canSchedule else { return }
        scheduledAt = ScheduledPosting.defaultDate(now: now(), calendar: calendar)
    }

    /// 予約の日時を変える。予約の行を出していなければ何もしない。
    func setScheduledDate(_ date: Date) {
        guard !isPosting, scheduledAt != nil else { return }
        scheduledAt = date
    }

    /// 予約の行を外し、すぐ投稿する下書きに戻す。
    func removeSchedule() {
        guard !isPosting else { return }
        scheduledAt = nil
    }

    /// 予約の日時として選べる最も早い日時。
    var earliestScheduleDate: Date {
        ScheduledPosting.earliestDate(now: now(), calendar: calendar)
    }

    /// 投票の欄を出す。足せないときは何もしない。
    func addPoll() {
        guard poll == nil, canAddPoll else { return }
        // 締め切りは1日にする。サーバーの上限の外なら、選べるもののうち最初のもの。
        let choices = PollDraft.expiryChoices(within: pollLimits)
        poll = PollDraft(expiresIn: choices.contains(86_400) ? 86_400 : choices.first ?? pollLimits.expirationRange.lowerBound)
    }

    /// 選択肢を書き換える。最後の欄に書くと上限まで空の欄が増え、後ろに空の欄が並ぶと詰める。決まりは`PollDraft.setOption`にある。
    func setPollOption(_ text: String, at index: Int) {
        guard !isPosting else { return }
        poll?.setOption(text, at: index, limits: pollLimits)
    }

    /// 投票の欄を外す。書いた選択肢も捨てる。
    func removePoll() {
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
    func canChoose(_ visibility: Status.Visibility) -> Bool {
        guard editedStatus == nil else { return false }
        guard let limit = quoteTarget.flatMap(StatusDraft.maxVisibility(quoting:)) else { return true }
        return visibility.narrower(limit) == visibility
    }

    /// インスタンスの上限と、ユーザーの既定の公開範囲、閲覧注意、言語を反映する。公開範囲と言語は、自分で選んでいたら変えない。
    /// 既定の閲覧注意は、この後に最初の添付を足したときから使う。
    /// - Parameter defaultLanguage: 既定の言語。読めなければnilで、今のままにする。既定を決めていなければ`.some(nil)`。
    func apply(configuration: InstanceConfiguration?, defaultVisibility: Status.Visibility?, defaultSensitive: Bool?, defaultLanguage: String?? = nil) {
        hasResolvedDefaults = true
        if let defaultLanguage {
            self.defaultLanguage = defaultLanguage
            if !hasChosenLanguage {
                language = defaultLanguage
            }
        }
        if let configuration {
            maxCharacters = configuration.maxCharacters
            charactersReservedPerURL = configuration.charactersReservedPerURL
            maxMediaAttachments = configuration.maxMediaAttachments
            mediaDescriptionLimit = configuration.mediaDescriptionLimit
            mediaLimits = configuration.mediaLimits
            pollLimits = configuration.pollLimits
            supportedMediaTypes = configuration.supportedMediaTypes
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

    /// 編集では公開範囲を変えられないため、選んでも変えない。引用元より広い範囲も変えない。
    func choose(_ visibility: Status.Visibility) {
        guard canChoose(visibility) else { return }
        self.visibility = visibility
        hasChosenVisibility = true
    }

    /// 本文のうち、返信先から自動で入れた宛先を除いた、自分で書いた部分。宛先を書き換えていたら本文全体。
    /// 編集では、元の本文も自分で書いたものなので本文全体。
    var typedText: String {
        guard editedStatus == nil, rewritingSchedule == nil else { return text }
        return text.hasPrefix(initialDraft.text) ? String(text.dropFirst(initialDraft.text.count)) : text
    }

    /// 編集のラベルの文字。返信の編集なら、誰への返信かも書く。返信先はメンションの中から探し、見つからなければ相手を書かない。
    var editChipTitle: String? {
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
    func setReplyTarget(_ status: Status?) {
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
    func setQuoteTarget(_ status: Status?) {
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
    var hasQuoteConflicts: Bool {
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
    var rewriteChipTitle: String? {
        guard rewritingSchedule != nil else { return nil }
        if initialDraft.quotedStatusID != nil { return "予約した引用を書き直し中" }
        if initialDraft.inReplyToID != nil { return "予約した返信を書き直し中" }
        return "予約を書き直し中"
    }

    /// 捨てると失われる、自分で書いたものがある。編集と予約の書き直しは書き換えていなくても、始めたこと自体を失うものとして扱う。
    /// 返信先から自動で入れた宛先と注意書きは数えない。
    var hasWrittenContent: Bool {
        editedStatus != nil
            || rewritingSchedule != nil
            || !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || (!spoilerText.isEmpty && spoilerText != initialDraft.spoilerText)
            || !(poll?.filledOptions.isEmpty ?? true)
    }

    /// 自分の投稿の編集を始める。今の下書きは捨てる。送っている間は始めずfalseを返す。
    /// 投票を送り直せない投稿（締め切りまで5分を切った）でも、下書きを変えずにfalseを返す。
    /// 本文と注意書きは、HTMLの`content`ではなく、書いたときのソースから入れる。
    @discardableResult
    func beginEditing(_ status: Status, source: StatusSource, now: Date = AppDependencies.now()) -> Bool {
        guard !isPosting, let draft = StatusDraft.edit(of: status, source: source, now: now) else { return false }
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
        language = draft.language
        hasChosenLanguage = true
        lastSubmitted = nil
        hasChosenVisibility = false
        return true
    }

    /// 予約した投稿を書き直し始める。今の下書きは捨てる。送っている間は始めずfalseを返す。
    /// 予約したときの内容と日時を戻す。元の予約は、送れたあとに取り消させる。
    @discardableResult
    func beginRewriting(_ scheduled: ScheduledStatus) -> Bool {
        guard !isPosting else { return false }
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
        // 言語を送っていない予約は、送らずにサーバーに任せたままにする。
        language = draft.language
        hasChosenLanguage = true
        lastSubmitted = nil
        // 予約したときの公開範囲を、あとから届く既定の公開範囲で上書きしない。公開範囲を送っていない予約は、既定の公開範囲が届くのを待つ。
        hasChosenVisibility = scheduled.params.visibility != nil
        return true
    }

    /// 下書きを空にして、返信先のない新しい投稿に戻す。編集していれば、編集をやめる。
    func reset() {
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
        removeAllAttachments()
        lastSubmitted = nil
        hasChosenVisibility = false
        visibility = resolvedVisibility
        // 選んだ言語を次の投稿に残さない。たまに英語で書いたあとの投稿まで、英語として送らないため。
        hasChosenLanguage = false
        language = defaultLanguage
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
    func submit() async {
        guard canPost else { return }
        if let scheduledAt, !ScheduledPosting.accepts(scheduledAt, now: now()) {
            logger.info("compose: schedule too soon")
            errorMessage = "予約の日時は、今から5分より後にしてください。"
            return
        }
        UserAction.submitPost.record()
        isPosting = true
        let endBackgroundTime = backgroundTime("post status")
        defer {
            isPosting = false
            endBackgroundTime()
        }
        let draft = submission(of: draftToPost)
        lastSubmitted = draft
        do {
            try await post(draft)
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
            errorMessage = ErrorPresentation(error).text
        }
    }
}

// MARK: - メディアの添付

/// 添付したメディア1つの、端末の側だけで持つもの。
struct LocalMedia {
    /// ピッカーの`assetIdentifier`。開き直したときに前の選択として渡す。ペーストしたものはピッカーで選んでいないのでnil。
    let assetIdentifier: String?
    /// 読み込みを送り直すときに使う。前に選んだメディアはピッカーから読み直せないため、選んだときのものを持っておく。
    /// 引数のMIMEタイプの形式を避けて読み込む。
    let load: @MainActor (_ avoiding: Set<String>) async throws -> LocalMediaFile
    /// 添付から外したときに呼ぶ。ペーストしたものは足す前から読み込んでいて、`file`に入る前に外すとファイルが残るため、それを消す。
    var discardLoading: @MainActor () -> Void = {}
    /// 読み込んだファイル。読み込む前と、読み込みに失敗したときはnil。
    var file: LocalMediaFile?
    var thumbnail: UIImage?
    /// 失敗の理由。`DraftAttachment.State.failed`は理由を持たないため、ここに持つ。
    var failure: (any Error)?
    /// 代替テキストを送れなかった理由。送れないと`needsDescriptionUpdate`のまま止まるため、送り直す操作と表示に使う。
    var descriptionFailure: (any Error)?
    /// 送っている間の進み具合。0から1。
    var progress: Double = 0
    /// 端末で書き出している間と書き出したあとの進み具合。0から1。書き出さないならnil。
    var exportProgress: Double?
    /// 送るファイル。縮めるために作り直したら、そのファイル。作り直さないなら読み込んだファイル。決める前はnil。
    var sending: LocalMediaFile?
    /// サーバーの上限のために縮めたときの前と後。
    var reduction: MediaReduction?
    /// 送るファイルを、縮めるために作り直した。位置情報だけを除いて書き直したときは、元と同じ中身なのでfalse。切り抜いたときはtrue。
    var sendingIsReencoded = false
    /// 送る前に切り抜く範囲。`file`は元のまま残し、送るファイルを作るときに当てる。切り抜かないならnil。
    var crop: ImageCrop?
    /// 切り抜く範囲を変えた回数。切り抜いたファイルの名前に入れる。
    var cropCount = 0
    /// 動画に音声がある。読み込んで調べる前と、動画でないときはnil。
    var hasAudio: Bool?
    /// 動画の音声を除いて、GIFとして送る。Mastodonは音声のない動画をGIF（`gifv`）として扱うため。
    var removesAudio = false
    /// GIFとして送るかを切り替えた回数。作り直したファイルの名前に入れる。
    /// 止めた前のアップロードがまだ書いていることがあり、同じ名前だと切り替えるたびに書き合うため。
    var audioSwitchCount = 0

    /// GIFとして送るかと、切り替えた回数。
    var audioChoice: AudioChoice {
        AudioChoice(removesAudio: removesAudio, switchCount: audioSwitchCount)
    }

    /// 投稿欄とビューアで見せる種類。GIFとして送る動画はGIFにする。読み込む前はnil。
    var displayKind: MediaAttachment.Kind? {
        removesAudio ? .gifv : file?.kind
    }
}

/// 動画をGIFとして送るか（音声を除くか）と、切り替えた回数。切り替えた回数は、作り直したファイルの名前に入れる。
struct AudioChoice {
    var removesAudio = false
    var switchCount = 0
}

/// 添付1つの、投稿欄とビューアで見せる状態。
enum ComposeAttachmentStatus: Equatable {
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
struct MediaPreparationSettings {
    var imageSize: ImageUploadSize
    var videoSize: VideoUploadSize
    var imageQuality: Double
    var videoQuality: VideoPlan.Quality
    /// 書き出してから送るとき、進み具合の円のうち書き出しに割り振る割合。
    var exportProgressShare: Double

    /// 設定では縮めない。サーバーの上限を超えるものだけを縮める。メディアを添付しない画面とテストで使う。
    static let keepsOriginal = MediaPreparationSettings(
        imageSize: .original,
        videoSize: .original,
        imageQuality: TuningCatalog.mediaImageQuality.defaultValue,
        videoQuality: VideoPlan.Quality(bitRate1080p: 8_000_000, minimumBitRate1080p: 1_000_000, sizeLimitMargin: 0.95, audioBitRate: 128_000),
        exportProgressShare: TuningCatalog.mediaExportProgressShare.defaultValue
    )
}

/// 投稿欄がメディアのアップロードに使うもの。
struct ComposeMediaService {
    var upload: (MediaUpload) async throws -> MediaAttachment
    var waitUntilProcessed: (String) async throws -> MediaAttachment
    /// サーバーのIDと代替テキストを受け取り、`PUT /api/v1/media/:id`で送る。
    var updateDescription: (String, String) async throws -> MediaAttachment
    var makeThumbnail: (LocalMediaFile) async -> UIImage?
    /// 接続しているサーバーの今の版が処理できないと分かっている、画像の形式のMIMEタイプ。
    var unprocessableImageTypes: @MainActor () -> Set<String>
    /// 画像の形式を、接続しているサーバーの今の版では処理できないと覚える。
    var recordUnprocessableImageType: @MainActor (String) -> Void
    /// 送る前に縮める大きさと、作り直すときの好みの値。
    var preparation: @MainActor () -> MediaPreparationSettings

    /// メディアを添付しない画面とテストで使う。
    static var unavailable: ComposeMediaService {
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
    var attachedAssetIdentifiers: [String] {
        attachments.compactMap { localMedia[$0.id]?.assetIdentifier }
    }

    /// ピッカーで選べる枚数。編集している投稿に付いている添付とペーストした添付は、ピッカーの選択に入らないため、その分を除く。
    var pickerSelectionLimit: Int {
        max(maxMediaAttachments - attachments.filter { localMedia[$0.id]?.assetIdentifier == nil }.count, 0)
    }

    /// ピッカーの今の選択を取り込む。外されたものは添付から外し、足されたものは後ろに足してアップロードを始める。
    /// 投稿を待つ間も取り込む。ピッカーは選択が変わったことを覚えるので、捨てると投稿に失敗した後の下書きとピッカーの選択が食い違う。
    /// 送っている下書きは送る前にコピーしてあるので、ここで変えても影響しない。
    func applyPickerSelection(_ selection: [PickedMedia]) {
        let changes = pickerSelection.changes(current: attachedAssetIdentifiers, selected: selection.map(\.assetIdentifier))
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
    func addPastedMedia(_ pasted: [PastedMedia]) {
        let room = max(maxMediaAttachments - attachments.count, 0)
        let added = pasted.prefix(room)
        if attachments.isEmpty, defaultSensitive, !added.isEmpty {
            showsSpoiler = true
        }
        for media in added {
            let load = media.load
            let attachment = DraftAttachment()
            attachments.append(attachment)
            var local = LocalMedia(assetIdentifier: nil) { _ in try await load() }
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
    func mediaPickerDidClose() {
        pickerSelection.pickerDidClose()
    }

    /// 投稿欄から添付を外す。ピッカーを開いていれば、ピッカーがまだ選んだままの選択を送ってきても足し直さない。
    /// 編集している投稿に付いている添付とペーストした添付は、ピッカーで選んだものではないため、そのまま外す。
    func removeAttachment(_ id: DraftAttachment.ID, pickerIsOpen: Bool) {
        guard attachments.contains(where: { $0.id == id }) else { return }
        if let assetIdentifier = localMedia[id]?.assetIdentifier {
            pickerSelection.didRemoveInDraft(assetIdentifier, pickerIsOpen: pickerIsOpen)
        }
        discardAttachment(id)
    }

    /// 失敗した添付を送り直す。処理の待ち時間切れなら、サーバーに残っている同じIDで待ち直す。
    /// 代替テキストだけを送れなかったなら、代替テキストだけを送り直す。
    func retryAttachment(_ id: DraftAttachment.ID) {
        guard let attachment = attachments.first(where: { $0.id == id }) else { return }
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
    func setRemovesAudio(_ removesAudio: Bool, of id: DraftAttachment.ID) {
        guard let local = localMedia[id], local.hasAudio == true, local.removesAudio != removesAudio else { return }
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
    func setDescription(_ description: String, of id: DraftAttachment.ID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }), attachments[index].description != description else { return }
        attachments[index].description = description
        localMedia[id]?.descriptionFailure = nil
        sendDescriptionIfNeeded(id)
    }

    /// 切り抜ける添付。読み込み終えた画像で、編集している投稿にもう付いていないもの。GIFは動きを保ったまま切り抜けないので除く。
    func canCrop(_ id: DraftAttachment.ID) -> Bool {
        guard let attachment = attachments.first(where: { $0.id == id }), !attachment.isAttachedToStatus,
              let file = localMedia[id]?.file
        else { return false }
        return file.kind == .image && file.mimeType != "image/gif"
    }

    /// 切り抜く範囲を変え、アップロードし直す。Mastodonには、アップロード済みのメディアのファイルを差し替えるAPIがないため。
    /// 前のアップロードと代替テキストの送信は止め、前のメディアはどの投稿にも付かないまま残す。代替テキストはアップロードし直すときに一緒に送る。
    /// - Parameters:
    ///   - crop: 切り抜く範囲。切り抜かずに元のまま送るならnil。
    ///   - preview: 切り抜いた画像。送るファイルを作り終えるまで、投稿欄のサムネイルとビューアに出す。
    func setCrop(_ crop: ImageCrop?, preview: UIImage?, of id: DraftAttachment.ID) {
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
    func moveAttachment(_ id: DraftAttachment.ID, to index: Int) {
        guard let from = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments.remove(at: from)
        attachments.insert(attachment, at: min(max(index, 0), attachments.count))
    }

    /// 書き出しと送信の進み具合を1つにまとめた値。0から1。どちらもしていなければnil。
    /// 書き出すときは、円の前半を書き出し、後半を送信に割り振る。段階ごとに円を出し直すと、満ちた円がまた0から始まって見えるため。
    func attachmentProgress(of id: DraftAttachment.ID) -> Double? {
        guard let status = attachmentStatus(of: id), status == .exporting || status == .uploading, let local = localMedia[id] else { return nil }
        guard let export = local.exportProgress else { return local.progress }
        let share = media.preparation().exportProgressShare
        return share * export + (1 - share) * (status == .exporting ? 0 : local.progress)
    }

    /// 投稿欄とビューアで見せる状態。
    func attachmentStatus(of id: DraftAttachment.ID) -> ComposeAttachmentStatus? {
        guard let attachment = attachments.first(where: { $0.id == id }) else { return nil }
        switch attachment.state {
        case .uploading:
            if let export = localMedia[id]?.exportProgress, export < 1, localMedia[id]?.sending == nil { return .exporting }
            return .uploading
        case .processing: return .processing
        case .failed: return .failed
        case .uploaded:
            if descriptionTasks[id] != nil { return .sendingDescription }
            guard attachment.needsDescriptionUpdate else { return .ready }
            return localMedia[id]?.descriptionFailure == nil ? .sendingDescription : .descriptionFailed
        }
    }

    private func discardAttachment(_ id: DraftAttachment.ID) {
        uploadTasks.removeValue(forKey: id)?.cancel()
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

    func removeAllAttachments() {
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
        uploadTasks[id] = tasks.run { [weak self] in await self?.upload(id) }
    }

    /// ファイルを読み込み、アップロードし、サーバーでの変換が済むまで待つ。途中で添付から外されたら、何も書き戻さない。
    private func upload(_ id: DraftAttachment.ID) async {
        guard let local = localMedia[id], attachments.contains(where: { $0.id == id }) else { return }
        let endBackgroundTime = backgroundTime("upload attachment")
        defer { endBackgroundTime() }
        localMedia[id]?.failure = nil
        localMedia[id]?.descriptionFailure = nil
        var sentDescription: String?
        do {
            let processed: MediaAttachment
            setState(.uploading, of: id)
            let file = try await loadFile(id, local: local)
            // GIFとして送るかは、始めた時点の値で決める。待っている間に切り替わると、止めたこの処理が新しい処理と同じファイルに書くため。
            let sending = try await prepare(file, of: id, audio: local.audioChoice)
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
            if accepted.url == nil {
                setState(.processing(serverID: accepted.id), of: id)
                processed = try await media.waitUntilProcessed(accepted.id)
            } else {
                processed = accepted
            }
            try Task.checkCancellation()
            setState(.uploaded(processed), of: id)
            if let sentDescription {
                acceptServerDescription(of: id, sent: sentDescription, returned: processed)
            }
            sendDescriptionIfNeeded(id)
        } catch {
            guard !Task.isCancelled, localMedia[id] != nil else { return }
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
        let upload = try await LocalMediaLoader.upload(of: file, description: description)
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
    private func reloadFile(_ id: DraftAttachment.ID, local: LocalMedia, avoiding rejected: LocalMediaFile) async throws -> LocalMediaFile {
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
    private func loadFile(_ id: DraftAttachment.ID, local: LocalMedia) async throws -> LocalMediaFile {
        if let file = local.file { return file }
        let file = try await local.load(media.unprocessableImageTypes())
        guard localMedia[id] != nil, !Task.isCancelled else {
            file.remove()
            throw CancellationError()
        }
        localMedia[id]?.file = file
        thumbnailTasks[id] = tasks.run { [weak self, media] in
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
        descriptionTasks[id] = tasks.run { [weak self, media] in
            do {
                let updated = try await media.updateDescription(serverID, description)
                guard let self, !Task.isCancelled else { return }
                self.descriptionTasks[id] = nil
                self.setState(.uploaded(updated), of: id)
                self.acceptServerDescription(of: id, sent: description, returned: updated)
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
