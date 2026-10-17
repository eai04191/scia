import Foundation
import Observation
import SciaCore
import UIKit

/// 投稿欄の下書きの状態。タブバーの上の入力欄と、展開した投稿画面で同じものを使う。
@MainActor
@Observable
final class ComposeModel {
    var text: String
    var spoilerText: String
    /// 注意書きの欄を出している。隠しているときは注意書きなしで投稿する。
    var showsSpoiler: Bool
    private(set) var visibility: Status.Visibility
    /// 返信先。新しい投稿ならnil。
    private(set) var replyTo: Status?
    private(set) var maxCharacters = 500
    private(set) var charactersReservedPerURL = 23
    private(set) var maxMediaAttachments = 4
    /// 代替テキストの文字数の上限。
    private(set) var mediaDescriptionLimit = 1500
    private(set) var isPosting = false
    var errorMessage: String?
    /// 添付したメディア。この順で投稿に並ぶ。
    private(set) var attachments: [DraftAttachment] = []
    /// 添付したメディアごとの、端末の側だけで持つもの。
    private(set) var localMedia: [DraftAttachment.ID: LocalMedia] = [:]

    /// 返信先から自動で入れた宛先と注意書き。返信先を替えたとき、自分で書いた部分と見分けるために使う。
    @ObservationIgnored private var initialDraft: StatusDraft
    /// 公開範囲を自分で選んだ。後から既定値が届いても上書きしない。
    private var hasChosenVisibility = false
    /// 既定の公開範囲を読み終えた、または読めなかった。読み終えるまでは、既定より広い範囲で投稿しないよう、選ばない限り投稿させない。
    private var hasResolvedDefaults = false
    @ObservationIgnored private var defaultVisibility: Status.Visibility?
    /// サーバーの上限を読めた。読めるまでは、添付の枚数の上限が分からないのでメディアを選ばせない。
    private var hasLoadedConfiguration = false
    /// 最後に送った内容。同じ内容を送り直すときだけ同じIdempotency-Keyを使い、変えたら別の投稿として新しいキーにする。
    /// 応答だけが失われていた場合に、変えた内容が投稿されないまま成功扱いにならないようにするため。
    @ObservationIgnored private var lastSubmitted: StatusDraft?
    @ObservationIgnored private let myAccountID: String
    @ObservationIgnored private let post: (StatusDraft) async throws -> Void
    @ObservationIgnored private let media: ComposeMediaService
    @ObservationIgnored private var uploadTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    /// 代替テキストを送っている添付。送っている間は、書き戻してサーバーの値と同じになっても、送り終えるまで投稿させない。
    /// 送り終えた後のサーバーの値が、書き戻した値と違うことがあるため。投稿の可否が変わるので、変更を見張れるようにする。
    private var descriptionTasks: [DraftAttachment.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pickerSelection = MediaPickerSelection()
    /// 投稿できて、下書きを空に戻したあとに呼ぶ。
    @ObservationIgnored var onPosted: () -> Void = {}

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
        draft.visibility = visibility
        draft.attachments = attachments
        return draft
    }

    var remainingCharacters: Int {
        maxCharacters - draftToPost.length(charactersReservedPerURL: charactersReservedPerURL)
    }

    var canPost: Bool {
        !isPosting && descriptionTasks.isEmpty && (hasResolvedDefaults || hasChosenVisibility) && draftToPost.canPost(maxCharacters: maxCharacters, charactersReservedPerURL: charactersReservedPerURL, maxMediaAttachments: maxMediaAttachments)
    }

    /// メディアを選べる。枚数の上限をサーバーの値で読むまでは、ピッカーを開かない。
    /// 読めなかったときは、次に書き始めたときに読み直す。
    var canAttachMedia: Bool {
        !isPosting && hasLoadedConfiguration
    }

    /// 返信先と既定値から決まる公開範囲。
    private var resolvedVisibility: Status.Visibility {
        let base = defaultVisibility ?? .public
        return replyTo.map { StatusDraft.reply(to: $0, myAccountID: myAccountID, defaultVisibility: base).visibility } ?? base
    }

    /// インスタンスの上限と、ユーザーの既定の公開範囲を反映する。公開範囲を自分で選んでいたら変えない。
    func apply(configuration: InstanceConfiguration?, defaultVisibility: Status.Visibility?) {
        hasResolvedDefaults = true
        if let configuration {
            maxCharacters = configuration.maxCharacters
            charactersReservedPerURL = configuration.charactersReservedPerURL
            maxMediaAttachments = configuration.maxMediaAttachments
            mediaDescriptionLimit = configuration.mediaDescriptionLimit
            hasLoadedConfiguration = true
        }
        guard let defaultVisibility else { return }
        self.defaultVisibility = defaultVisibility
        guard !hasChosenVisibility else { return }
        visibility = resolvedVisibility
    }

    func choose(_ visibility: Status.Visibility) {
        self.visibility = visibility
        hasChosenVisibility = true
    }

    /// 本文のうち、返信先から自動で入れた宛先を除いた、自分で書いた部分。宛先を書き換えていたら本文全体。
    var typedText: String {
        text.hasPrefix(initialDraft.text) ? String(text.dropFirst(initialDraft.text.count)) : text
    }

    /// 返信先を付け替える。nilなら新しい投稿に戻す。
    ///
    /// 自分で書いた本文は残し、前の返信先から自動で入れた宛先だけを入れ替える。宛先を書き換えていたら、本文はそのまま残して新しい宛先を前に足す。
    /// 注意書きも、前の返信先から引き継いだままなら入れ替え、自分で書き換えていれば残す。
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
        let keepsSpoiler = showsSpoiler && spoilerText != initialDraft.spoilerText
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

    /// 下書きを空にして、返信先のない新しい投稿に戻す。
    func reset() {
        initialDraft = StatusDraft()
        replyTo = nil
        text = ""
        spoilerText = ""
        showsSpoiler = false
        removeAllAttachments()
        lastSubmitted = nil
        hasChosenVisibility = false
        visibility = resolvedVisibility
    }

    private func submission(of draft: StatusDraft) -> StatusDraft {
        guard let lastSubmitted else { return draft }
        if lastSubmitted.text == draft.text, lastSubmitted.spoilerText == draft.spoilerText, lastSubmitted.visibility == draft.visibility,
           lastSubmitted.mediaIDs == draft.mediaIDs {
            return lastSubmitted
        }
        return StatusDraft(text: draft.text, spoilerText: draft.spoilerText, visibility: draft.visibility, inReplyToID: draft.inReplyToID, attachments: draft.attachments)
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
            errorMessage = ErrorPresentation(error).text
        }
    }
}

// MARK: - メディアの添付

/// 添付したメディア1つの、端末の側だけで持つもの。
struct LocalMedia {
    /// ピッカーの`assetIdentifier`。開き直したときに前の選択として渡す。
    let assetIdentifier: String
    /// 読み込みを送り直すときに使う。前に選んだメディアはピッカーから読み直せないため、選んだときのものを持っておく。
    let load: @MainActor () async throws -> LocalMediaFile
    /// 読み込んだファイル。読み込む前と、読み込みに失敗したときはnil。
    var file: LocalMediaFile?
    var thumbnail: UIImage?
    /// 失敗の理由。`DraftAttachment.State.failed`は理由を持たないため、ここに持つ。再試行が待ち直しか送り直しかも、これで決める。
    var failure: (any Error)?
    /// 代替テキストを送れなかった理由。送れないと`needsDescriptionUpdate`のまま止まるため、送り直す操作と表示に使う。
    var descriptionFailure: (any Error)?
}

/// 添付1つの、投稿欄とビューアで見せる状態。
enum ComposeAttachmentStatus: Equatable {
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

/// 投稿欄がメディアのアップロードに使うもの。
struct ComposeMediaService {
    var upload: (MediaUpload) async throws -> MediaAttachment
    var waitUntilProcessed: (String) async throws -> MediaAttachment
    /// サーバーのIDと代替テキストを受け取り、`PUT /api/v1/media/:id`で送る。
    var updateDescription: (String, String) async throws -> MediaAttachment
    var makeThumbnail: (LocalMediaFile) async -> UIImage?

    /// メディアを添付しない画面とテストで使う。
    static var unavailable: ComposeMediaService {
        ComposeMediaService(
            upload: { _ in throw CancellationError() },
            waitUntilProcessed: { _ in throw CancellationError() },
            updateDescription: { _, _ in throw CancellationError() },
            makeThumbnail: { _ in nil }
        )
    }
}

extension ComposeModel {
    /// ピッカーに前の選択として渡すID。添付の並び順。
    var attachedAssetIdentifiers: [String] {
        attachments.compactMap { localMedia[$0.id]?.assetIdentifier }
    }

    /// ピッカーの今の選択を取り込む。外されたものは添付から外し、足されたものは後ろに足してアップロードを始める。
    /// 投稿を待つ間も取り込む。ピッカーは選択が変わったことを覚えるので、捨てると投稿に失敗した後の下書きとピッカーの選択が食い違う。
    /// 送っている下書きは送る前にコピーしてあるので、ここで変えても影響しない。
    func applyPickerSelection(_ selection: [PickedMedia]) {
        let changes = pickerSelection.changes(current: attachedAssetIdentifiers, selected: selection.map(\.assetIdentifier))
        let removed = Set(changes.removed)
        for attachment in attachments where localMedia[attachment.id].map({ removed.contains($0.assetIdentifier) }) ?? false {
            discardAttachment(attachment.id)
        }
        let added = Set(changes.added)
        for picked in selection where added.contains(picked.assetIdentifier) {
            let attachment = DraftAttachment()
            attachments.append(attachment)
            localMedia[attachment.id] = LocalMedia(assetIdentifier: picked.assetIdentifier, load: picked.load)
            startUpload(attachment.id)
        }
    }

    /// ピッカーを閉じた。
    func mediaPickerDidClose() {
        pickerSelection.pickerDidClose()
    }

    /// 投稿欄から添付を外す。ピッカーを開いていれば、ピッカーがまだ選んだままの選択を送ってきても足し直さない。
    func removeAttachment(_ id: DraftAttachment.ID, pickerIsOpen: Bool) {
        guard let assetIdentifier = localMedia[id]?.assetIdentifier else { return }
        pickerSelection.didRemoveInDraft(assetIdentifier, pickerIsOpen: pickerIsOpen)
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

    /// 投稿欄とビューアで見せる状態。
    func attachmentStatus(of id: DraftAttachment.ID) -> ComposeAttachmentStatus? {
        guard let attachment = attachments.first(where: { $0.id == id }) else { return nil }
        switch attachment.state {
        case .uploading: return .uploading
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
        localMedia.removeValue(forKey: id)?.file?.remove()
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
                // 読み込む間に書いた代替テキストも一緒に送れるよう、送る直前の値を読む。
                let description = attachments.first { $0.id == id }?.description ?? ""
                sentDescription = description
                let accepted = try await media.upload(LocalMediaLoader.upload(of: file, description: description))
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
            localMedia[id]?.failure = error
            setState(.failed(serverID: attachments.first { $0.id == id }?.serverID), of: id)
        }
    }

    /// 読み込み済みならそのファイルを使う。初めて読み込んだら、サムネイルも作り始める。
    private func loadFile(_ id: DraftAttachment.ID, local: LocalMedia) async throws -> LocalMediaFile {
        if let file = local.file { return file }
        let file = try await local.load()
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
