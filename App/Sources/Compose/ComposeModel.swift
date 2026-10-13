import Foundation
import Observation
import SciaCore

/// 投稿画面の状態。
@MainActor
@Observable
final class ComposeModel {
    var text: String
    var spoilerText: String
    /// 注意書きの欄を出している。隠しているときは注意書きなしで投稿する。
    var showsSpoiler: Bool
    private(set) var visibility: Status.Visibility
    /// 返信先。新しい投稿ならnil。
    let replyTo: Status?
    private(set) var maxCharacters = 500
    private(set) var charactersReservedPerURL = 23
    private(set) var isPosting = false
    var errorMessage: String?
    var isDiscardConfirmationPresented = false

    @ObservationIgnored private let initialDraft: StatusDraft
    /// 公開範囲を自分で選んだ。後から既定値が届いても上書きしない。
    private var hasChosenVisibility = false
    /// 既定の公開範囲を読み終えた、または読めなかった。読み終えるまでは、既定より広い範囲で投稿しないよう、選ばない限り投稿させない。
    private var hasResolvedDefaults = false
    /// 最後に送った内容。同じ内容を送り直すときだけ同じIdempotency-Keyを使い、変えたら別の投稿として新しいキーにする。
    /// 応答だけが失われていた場合に、変えた内容が投稿されないまま成功扱いにならないようにするため。
    @ObservationIgnored private var lastSubmitted: StatusDraft?
    @ObservationIgnored private let myAccountID: String
    @ObservationIgnored private let post: (StatusDraft) async throws -> Void
    /// 画面を閉じるときに呼ぶ。
    @ObservationIgnored var onFinish: () -> Void = {}

    init(replyTo: Status?, myAccountID: String, post: @escaping (StatusDraft) async throws -> Void) {
        let draft = replyTo.map { StatusDraft.reply(to: $0, myAccountID: myAccountID) } ?? StatusDraft()
        initialDraft = draft
        text = draft.text
        spoilerText = draft.spoilerText
        showsSpoiler = !draft.spoilerText.isEmpty
        visibility = draft.visibility
        self.replyTo = replyTo
        self.myAccountID = myAccountID
        self.post = post
    }

    /// 送る内容。注意書きの欄を隠していれば、注意書きは送らない。
    private var draftToPost: StatusDraft {
        var draft = initialDraft
        draft.text = text
        draft.spoilerText = showsSpoiler ? spoilerText : ""
        draft.visibility = visibility
        return draft
    }

    var remainingCharacters: Int {
        maxCharacters - draftToPost.length(charactersReservedPerURL: charactersReservedPerURL)
    }

    var canPost: Bool {
        !isPosting && (hasResolvedDefaults || hasChosenVisibility) && draftToPost.canPost(maxCharacters: maxCharacters, charactersReservedPerURL: charactersReservedPerURL)
    }

    /// 開いたときから書き換えている。閉じる前に破棄してよいか確かめる。
    var isDirty: Bool {
        text != initialDraft.text || (showsSpoiler ? spoilerText : "") != initialDraft.spoilerText
    }

    /// インスタンスの上限と、ユーザーの既定の公開範囲を反映する。公開範囲を自分で選んでいたら変えない。
    func apply(configuration: InstanceConfiguration?, defaultVisibility: Status.Visibility?) {
        hasResolvedDefaults = true
        if let configuration {
            maxCharacters = configuration.maxCharacters
            charactersReservedPerURL = configuration.charactersReservedPerURL
        }
        guard let defaultVisibility, !hasChosenVisibility else { return }
        visibility = replyTo.map { StatusDraft.reply(to: $0, myAccountID: myAccountID, defaultVisibility: defaultVisibility).visibility } ?? defaultVisibility
    }

    func choose(_ visibility: Status.Visibility) {
        self.visibility = visibility
        hasChosenVisibility = true
    }

    private func submission(of draft: StatusDraft) -> StatusDraft {
        guard let lastSubmitted else { return draft }
        if lastSubmitted.text == draft.text, lastSubmitted.spoilerText == draft.spoilerText, lastSubmitted.visibility == draft.visibility {
            return lastSubmitted
        }
        return StatusDraft(text: draft.text, spoilerText: draft.spoilerText, visibility: draft.visibility, inReplyToID: draft.inReplyToID)
    }

    func cancel() {
        if isDirty {
            isDiscardConfirmationPresented = true
        } else {
            onFinish()
        }
    }

    /// 投稿し、成功したら閉じる。失敗したら下書きを残し、同じ下書きで送り直せるようにする。
    func submit() async {
        guard canPost else { return }
        isPosting = true
        defer { isPosting = false }
        let draft = submission(of: draftToPost)
        lastSubmitted = draft
        do {
            try await post(draft)
            onFinish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
