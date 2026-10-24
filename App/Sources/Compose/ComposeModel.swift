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

    /// 返信先から自動で入れた宛先と注意書き。返信先を替えたとき、自分で書いた部分と見分けるために使う。
    @ObservationIgnored private var initialDraft: StatusDraft
    /// 公開範囲を自分で選んだ。後から既定値が届いても上書きしない。
    private var hasChosenVisibility = false
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
    @ObservationIgnored private let post: (StatusDraft) async throws -> Void
    @ObservationIgnored private let media: ComposeMediaService
    @ObservationIgnored private var uploadTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    /// 代替テキストを送っている添付。送っている間は、書き戻してサーバーの値と同じになっても、送り終えるまで投稿させない。
    /// 送り終えた後のサーバーの値が、書き戻した値と違うことがあるため。投稿の可否が変わるので、変更を見張れるようにする。
    private var descriptionTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pickerSelection = MediaPickerSelection()
    @ObservationIgnored private let logger = SciaLog.logger(category: "compose")
    /// 投稿できて、下書きを空に戻したあとに呼ぶ。
    @ObservationIgnored var onPosted: () -> Void = {}
    /// サーバーの上限のために、設定で選んだより小さく、または低い画質にした。使う人が選んでいない画質の変化なので、知らせる。
    @ObservationIgnored var onMediaReduced: (MediaAttachment.Kind) -> Void = { _ in }
    /// ペーストしたメディアのうち、添付の上限を超えて足さなかったものの種類。
    @ObservationIgnored var onPastedMediaSkipped: ([MediaAttachment.Kind]) -> Void = { _ in }

    init(replyTo: Status? = nil, myAccountID: String, media: ComposeMediaService = .unavailable, post: @escaping (StatusDraft) async throws -> Void) {
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
        return draft
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
    /// 投票の欄を出している間も開かない。Mastodonは投票と添付を一緒に付けられないため。
    var canAttachMedia: Bool {
        !isPosting && hasLoadedConfiguration && pickerSelectionLimit > 0 && poll == nil
    }

    /// メディアをペーストできる。ピッカーと違い、上限まで埋まっていても受け付け、入りきらない分を知らせる。
    /// 投票の欄を出している間は受け付けない。
    var canPasteMedia: Bool {
        !isPosting && hasLoadedConfiguration && poll == nil
    }

    /// 投票の欄を足せる。添付があるときは、Mastodonが一緒に付けられないため足せない。
    /// 編集では足せない。投票の付いた投稿の編集は、元の投票をそのまま送り直す。決まりはdocs/compose.mdの「自分の投稿の編集」にある。
    var canAddPoll: Bool {
        !isPosting && attachments.isEmpty && editedStatus == nil
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

    /// 返信先と既定値から決まる公開範囲。
    private var resolvedVisibility: Status.Visibility {
        let base = defaultVisibility ?? .public
        return replyTo.map { StatusDraft.reply(to: $0, myAccountID: myAccountID, defaultVisibility: base).visibility } ?? base
    }

    /// インスタンスの上限と、ユーザーの既定の公開範囲と閲覧注意を反映する。公開範囲を自分で選んでいたら変えない。
    /// 既定の閲覧注意は、この後に最初の添付を足したときから使う。
    func apply(configuration: InstanceConfiguration?, defaultVisibility: Status.Visibility?, defaultSensitive: Bool?) {
        hasResolvedDefaults = true
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

    /// 編集では公開範囲を変えられないため、選んでも変えない。
    func choose(_ visibility: Status.Visibility) {
        guard editedStatus == nil else { return }
        self.visibility = visibility
        hasChosenVisibility = true
    }

    /// 本文のうち、返信先から自動で入れた宛先を除いた、自分で書いた部分。宛先を書き換えていたら本文全体。
    /// 編集では、元の本文も自分で書いたものなので本文全体。
    var typedText: String {
        guard editedStatus == nil else { return text }
        return text.hasPrefix(initialDraft.text) ? String(text.dropFirst(initialDraft.text.count)) : text
    }

    /// 編集の札の文字。返信の編集なら、誰への返信かも書く。返信先はメンションの中から探し、見つからなければ相手を書かない。
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
    func setReplyTarget(_ status: Status?) {
        guard !isPosting else { return }
        // 同じ投稿を元の投稿とブーストのように別の場所から選び直したときは、下書きを保ったまま、札が指す先だけを選んだ方にする。
        if let status, status.displayed.id == replyTo?.displayed.id {
            replyTo = status
            return
        }
        guard status != nil || replyTo != nil else { return }
        let typed = typedText
        let keepsSpoiler = showsSpoiler && (spoilerText != initialDraft.spoilerText || initialDraft.spoilerText.isEmpty)
        initialDraft = status.map { StatusDraft.reply(to: $0, myAccountID: myAccountID) } ?? StatusDraft()
        replyTo = status
        text = initialDraft.text + typed
        if !keepsSpoiler {
            spoilerText = initialDraft.spoilerText
            showsSpoiler = !spoilerText.isEmpty
        }
        lastSubmitted = nil
        hasChosenVisibility = false
        visibility = resolvedVisibility
    }

    /// 捨てると失われる、自分で書いたものがある。編集は書き換えていなくても、始めたこと自体を失うものとして扱う。
    /// 返信先から自動で入れた宛先と注意書きは数えない。
    var hasWrittenContent: Bool {
        editedStatus != nil
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
        text = draft.text
        spoilerText = draft.spoilerText
        showsSpoiler = draft.hasSpoiler
        visibility = draft.visibility
        attachments = draft.attachments
        poll = nil
        lastSubmitted = nil
        hasChosenVisibility = false
        return true
    }

    /// 下書きを空にして、返信先のない新しい投稿に戻す。編集していれば、編集をやめる。
    func reset() {
        initialDraft = StatusDraft()
        replyTo = nil
        editedStatus = nil
        text = ""
        spoilerText = ""
        showsSpoiler = false
        poll = nil
        removeAllAttachments()
        lastSubmitted = nil
        hasChosenVisibility = false
        visibility = resolvedVisibility
    }

    /// 編集には`Idempotency-Key`を付けないため、そのまま送る。同じ編集を送り直しても、サーバーは変化がなければ編集として残さない。
    private func submission(of draft: StatusDraft) -> StatusDraft {
        guard draft.editing == nil, let lastSubmitted else { return draft }
        if lastSubmitted.text == draft.text, lastSubmitted.spoilerText == draft.spoilerText, lastSubmitted.sensitive == draft.sensitive,
           lastSubmitted.visibility == draft.visibility, lastSubmitted.mediaIDs == draft.mediaIDs, lastSubmitted.poll == draft.poll {
            return lastSubmitted
        }
        return StatusDraft(text: draft.text, spoilerText: draft.spoilerText, hasSpoiler: draft.hasSpoiler, visibility: draft.visibility, inReplyToID: draft.inReplyToID, attachments: draft.attachments, poll: draft.poll)
    }

    /// 投稿し、成功したら下書きを空に戻す。失敗したら下書きを残し、同じ下書きで送り直せるようにする。
    func submit() async {
        guard canPost else { return }
        UserAction.submitPost.record()
        isPosting = true
        defer { isPosting = false }
        let draft = submission(of: draftToPost)
        lastSubmitted = draft
        do {
            try await post(draft)
            reset()
            onPosted()
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
    /// 失敗の理由。`DraftAttachment.State.failed`は理由を持たないため、ここに持つ。再試行が待ち直しか送り直しかも、これで決める。
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
    /// 送るファイルを、縮めるために作り直した。位置情報だけを除いて書き直したときは、元と同じ中身なのでfalse。
    var sendingIsReencoded = false
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

    /// 代替テキストを書き換える。アップロードが済んでいればすぐ送り、済む前ならアップロードと一緒に（間に合わなければ済んでから）送る。
    func setDescription(_ description: String, of id: DraftAttachment.ID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }), attachments[index].description != description else { return }
        attachments[index].description = description
        localMedia[id]?.descriptionFailure = nil
        sendDescriptionIfNeeded(id)
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
        uploadTasks[id] = Task { [weak self] in await self?.upload(id) }
    }

    /// ファイルを読み込み、アップロードし、サーバーでの変換が済むまで待つ。途中で添付から外されたら、何も書き戻さない。
    private func upload(_ id: DraftAttachment.ID) async {
        guard let local = localMedia[id], attachments.contains(where: { $0.id == id }) else { return }
        localMedia[id]?.failure = nil
        localMedia[id]?.descriptionFailure = nil
        var sentDescription: String?
        do {
            let processed: MediaAttachment
            if case .processingTimedOut(let serverID) = local.failure as? MediaUploadError {
                setState(.processing(serverID: serverID), of: id)
                processed = try await media.waitUntilProcessed(serverID)
            } else {
                setState(.uploading, of: id)
                let file = try await loadFile(id, local: local)
                let sending = try await prepare(file, of: id)
                let accepted: MediaAttachment
                do {
                    accepted = try await send(sending, of: id, sentDescription: &sentDescription)
                } catch let error where UnprocessableMediaFormats.shouldReplaceWithJPEG(mimeType: sending.mimeType, error: error) {
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
            }
            try Task.checkCancellation()
            setState(.uploaded(processed), of: id)
            if let sentDescription {
                acceptServerDescription(of: id, sent: sentDescription, returned: processed)
            }
            sendDescriptionIfNeeded(id)
        } catch {
            guard !Task.isCancelled, localMedia[id] != nil else { return }
            logger.info("attachment upload failed error=\(String(describing: error), privacy: .public)")
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
    private func prepare(_ file: LocalMediaFile, of id: DraftAttachment.ID, forcingJPEG: Bool = false) async throws -> LocalMediaFile {
        if let sending = localMedia[id]?.sending { return sending }
        let settings = media.preparation()
        let byteCount = ImageReencoder.byteCount(of: file.url)
        let prepared: PreparedMedia?
        var reencoded = false
        switch file.kind {
        case .image:
            guard let size = ImageReencoder.size(of: file.url) else { throw MediaReencodingError.imageFailed }
            let plan = ImagePlan.make(
                size: size, byteCount: byteCount, mimeType: file.mimeType, setting: settings.imageSize, limits: mediaLimits,
                supportedMIMETypes: supportedMediaTypes,
                unprocessableMIMETypes: media.unprocessableImageTypes().union(forcingJPEG ? UnprocessableMediaFormats.replaceableMIMETypes : [])
            )
            reencoded = plan != nil
            prepared = if let plan {
                try await ImageReencoder.reencode(
                    file.url, plan: plan, originalSize: size, sizeLimit: mediaLimits.imageSizeLimit, quality: settings.imageQuality,
                    destination: Self.preparedURL(for: file)
                )
            } else {
                try await LocationRemover.removingLocation(fromImage: file.url, destination: Self.preparedURL(for: file))
                    .map { PreparedMedia(url: $0, mimeType: file.mimeType, size: size, reduction: nil) }
            }
        case .video:
            (prepared, reencoded) = try await prepareVideo(file, of: id, byteCount: byteCount, settings: settings)
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
        byteCount: Int,
        settings: MediaPreparationSettings
    ) async throws -> (PreparedMedia?, reencoded: Bool) {
        guard let info = await VideoReencoder.info(of: file.url) else { throw MediaReencodingError.videoFailed }
        let plan = VideoPlan.make(
            size: info.size, duration: info.duration, frameRate: info.frameRate, hasAudio: info.hasAudio, byteCount: byteCount,
            setting: settings.videoSize, limits: mediaLimits, quality: settings.videoQuality
        )
        switch plan {
        case .original:
            // 書き出す動画には位置情報を書かないので、元のまま送るときだけ除く。
            let cleaned = try await LocationRemover.removingLocation(fromVideo: file.url, destination: Self.preparedURL(for: file))
            return (cleaned.map { PreparedMedia(url: $0, mimeType: file.mimeType, size: info.size, reduction: nil) }, false)
        case .tooLong:
            throw MediaReencodingError.videoTooLong
        case .export(let size, let frameRate, let bitRate, let reducedByServer):
            localMedia[id]?.exportProgress = 0
            let destination = Self.preparedURL(for: file).deletingPathExtension().appendingPathExtension("mp4")
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in self?.setExportProgress(fraction, of: id) }
            }
            try await VideoReencoder.export(
                file.url, size: size, frameRate: frameRate, bitRate: bitRate, audioBitRate: settings.videoQuality.audioBitRate,
                destination: destination, progress: report
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
    private static func preparedURL(for file: LocalMediaFile) -> URL {
        file.url.deletingLastPathComponent().appending(path: "prepared-" + file.url.lastPathComponent)
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
        thumbnailTasks[id] = Task { [weak self, media] in
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
        descriptionTasks[id] = Task { [weak self, media] in
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
