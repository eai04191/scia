import Foundation
import Observation
import SciaCore

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
    private(set) var isPosting = false
    var errorMessage: String?

    /// 返信先から自動で入れた宛先と注意書き。返信先を替えたとき、自分で書いた部分と見分けるために使う。
    @ObservationIgnored private var initialDraft: StatusDraft
    /// 公開範囲を自分で選んだ。後から既定値が届いても上書きしない。
    private var hasChosenVisibility = false
    /// 既定の公開範囲を読み終えた、または読めなかった。読み終えるまでは、既定より広い範囲で投稿しないよう、選ばない限り投稿させない。
    private var hasResolvedDefaults = false
    @ObservationIgnored private var defaultVisibility: Status.Visibility?
    /// 最後に送った内容。同じ内容を送り直すときだけ同じIdempotency-Keyを使い、変えたら別の投稿として新しいキーにする。
    /// 応答だけが失われていた場合に、変えた内容が投稿されないまま成功扱いにならないようにするため。
    @ObservationIgnored private var lastSubmitted: StatusDraft?
    @ObservationIgnored private let myAccountID: String
    @ObservationIgnored private let post: (StatusDraft) async throws -> Void
    /// 投稿できて、下書きを空に戻したあとに呼ぶ。
    @ObservationIgnored var onPosted: () -> Void = {}

    init(replyTo: Status? = nil, myAccountID: String, post: @escaping (StatusDraft) async throws -> Void) {
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
    /// 注意書きも、前の返信先から写したままなら入れ替え、自分で書き換えていれば残す。
    /// 公開範囲は選び直しにする。新しい投稿で選んだ公開範囲のまま、フォロワー限定の投稿へ公開で返信してしまわないため。
    ///
    /// 送信を待つ間は変えない。送っている下書きと食い違い、成功して空に戻すときに新しい返信先まで消してしまうため。
    /// 同じ投稿を選び直したときも変えない。失敗した投稿を同じIdempotency-Keyで送り直せるようにするため。
    func setReplyTarget(_ status: Status?) {
        guard !isPosting, status?.displayed.id != replyTo?.displayed.id else { return }
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
        lastSubmitted = nil
        hasChosenVisibility = false
        visibility = resolvedVisibility
    }

    private func submission(of draft: StatusDraft) -> StatusDraft {
        guard let lastSubmitted else { return draft }
        if lastSubmitted.text == draft.text, lastSubmitted.spoilerText == draft.spoilerText, lastSubmitted.visibility == draft.visibility {
            return lastSubmitted
        }
        return StatusDraft(text: draft.text, spoilerText: draft.spoilerText, visibility: draft.visibility, inReplyToID: draft.inReplyToID)
    }

    /// 投稿し、成功したら下書きを空に戻す。失敗したら下書きを残し、同じ下書きで送り直せるようにする。
    func submit() async {
        guard canPost else { return }
        isPosting = true
        defer { isPosting = false }
        let draft = submission(of: draftToPost)
        lastSubmitted = draft
        do {
            try await post(draft)
            reset()
            onPosted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
