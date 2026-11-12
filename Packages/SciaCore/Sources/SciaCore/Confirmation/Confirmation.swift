public import Foundation

/// 操作の前に使う人に確かめる中身。題、説明、ボタンを持ち、描く側がアラートやアクションシートにする。
/// `Choice`は、押されたボタンが選んだもの。キャンセルのボタンは、閉じたときに片付けるものがなければ選ばない。
public struct Confirmation<Choice: Hashable & Sendable>: Equatable, Sendable {
    public enum Role: Sendable {
        case cancel
        case destructive
        case `default`
    }

    public struct Button: Equatable, Sendable {
        public let title: String
        public let role: Role
        /// 押したときに選ぶもの。選ばずに閉じるボタンではnil。
        public let choice: Choice?

        public init(_ title: String, role: Role, choice: Choice?) {
            self.title = title
            self.role = role
            self.choice = choice
        }

        public static var cancel: Button {
            Button("キャンセル", role: .cancel, choice: nil)
        }
    }

    public let title: String
    public let message: String?
    /// 並べる順。アラートとアクションシートでは、キャンセルのボタンの位置はOSが決める。
    public let buttons: [Button]

    public init(title: String, message: String?, buttons: [Button]) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }
}

/// 確かめるボタンが1つだけの確認で、押されたことを表す。
public enum Proceed: Hashable, Sendable {
    case proceed
}

/// 操作を始められないことを知らせる、OKだけのアラートの文言。
public struct RefusalText: Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// 書きかけの投稿欄で、新しく始める操作。決め方は`Confirmation.starting(_:draft:now:)`にある。
public enum ComposeStart: Sendable {
    /// 返信先を付けて書く。
    /// - Parameter switchesAccount: 投稿するアカウントを替えて始める（「別のアカウントで」）。
    case reply(switchesAccount: Bool)
    /// 引用元を付けて書く。
    case quote(switchesAccount: Bool)
    /// ほかのアカウントに替えて、メンションを入れて書く。今のアカウントのメンションは、本文に足すだけなので、ここを通さない。
    case mention
    /// 自分の投稿を編集する。
    /// - Parameter actor: ほかのアカウントとして編集するときの、そのアカウントの`@username`。見出しの初めに「〜で」と入れる。
    case edit(Status, actor: String?)
    /// 自分の投稿を削除して書き直す。
    case redraft(Status, actor: String?)
    /// 予約した投稿を書き直す。
    case rewrite

    /// 投稿するアカウントを替えて始める。
    var switchesAccount: Bool {
        switch self {
        case .reply(let switchesAccount), .quote(let switchesAccount): switchesAccount
        case .mention: true
        case .edit, .redraft, .rewrite: false
        }
    }

    /// 「返信」「引用」のような、確かめる見出しに書く操作の名前。
    var name: String {
        switch self {
        case .reply: "返信"
        case .quote: "引用"
        case .mention: "メンション"
        case .edit: "編集"
        case .redraft, .rewrite: "書き直し"
        }
    }
}

/// `ComposeStart`を始める前の決定。
public enum ComposeStartDecision: Equatable, Sendable {
    /// 確かめずに始める。
    case proceed
    /// 確かめてから始める。
    /// - Parameter leavesCurrentWork: 確かめたあと、始める前に、いまの編集や書き直しをやめて投稿欄を空に戻す。返信と引用は、編集や書き直しの本文を引き継がないため。
    case confirm(Confirmation<Proceed>, leavesCurrentWork: Bool)
    /// 始められない。理由をアラートで伝える。
    case refuse(RefusalText)
    /// 投稿を送っている間で、いまは始められないが、送り終えれば始められる。
    /// 待てば済むので、アラートで操作を止めずに、数秒で消えるチップ（`Notice.startWhilePosting`）で伝える（docs/vision.mdの「アプリ内通知」）。
    case waitUntilPosted

    init(_ decision: ConfirmationDecision<Proceed>, leavesCurrentWork: Bool = false) {
        self = switch decision {
        case .proceed: .proceed
        case .confirm(let confirmation): .confirm(confirmation, leavesCurrentWork: leavesCurrentWork)
        case .refuse(let text): .refuse(text)
        }
    }

    /// 確かめるときの文言。確かめなければnil。
    public var confirmation: Confirmation<Proceed>? {
        if case .confirm(let confirmation, _) = self { confirmation } else { nil }
    }
}

/// 確かめずに進めるか、確かめるか、始められないことを知らせるか。
public enum ConfirmationDecision<Choice: Hashable & Sendable>: Equatable, Sendable {
    case proceed
    case confirm(Confirmation<Choice>)
    case refuse(RefusalText)
}

extension Confirmation where Choice == Proceed {
    /// 赤いボタン1つとキャンセルで確かめる。
    static func destructive(title: String, message: String?, action: String) -> Confirmation {
        Confirmation(title: title, message: message, buttons: [.cancel, Button(action, role: .destructive, choice: .proceed)])
    }

    // MARK: - ユーザーとの関係

    /// フォローを外す、リクエストを取り消す、ブロックは、押し間違えに備えて確かめる。フォローとミュートなどは確かめない（nil）。
    /// ユーザーのメニューとプロフィールのフォローのボタンで同じ文言を使う。
    /// - Parameter endorsed: 相手を自分のプロフィールで紹介している。サーバーはフォローを外すと紹介も消すので、フォローを外すときに添える。
    /// - Parameter actor: 「別のアカウントで」で、ほかのアカウントとして行うときの、そのアカウントの名前（`@username`）。見出しの初めに「@usernameで」と入れる。
    public static func relationChange(_ change: UserRelationChange, acct: String, endorsed: Bool = false, actor: String? = nil) -> Confirmation? {
        let by = actor.map { "\($0)で" } ?? ""
        return switch change {
        case .unfollow:
            .destructive(title: "\(by)@\(acct)のフォローを外しますか？", message: endorsed ? "プロフィールでの紹介も外れます。" : nil, action: "フォローを外す")
        case .cancelFollowRequest:
            .destructive(title: "\(by)@\(acct)へのフォローリクエストを取り消しますか？", message: nil, action: "リクエストを取り消す")
        case .block:
            .destructive(title: "\(by)@\(acct)をブロックしますか？", message: "相手の投稿と通知が表示されなくなり、お互いのフォローが外れます。", action: "ブロック")
        case .follow, .showReblogs, .notify, .endorse, .mute, .unmute, .unblock:
            nil
        }
    }

    // MARK: - リスト

    /// フォローしていない人をリストに足すときは、Mastodonのwebと同じく、フォローしてから足してよいか確かめる。
    public static func followToList(acct: String) -> Confirmation {
        Confirmation(title: "@\(acct)をフォローしますか？", message: "リストに追加するにはフォローが必要です。", buttons: [.cancel, Button("フォローしてリストに追加", role: .default, choice: .proceed)])
    }

    /// リストを消すと、メンバーの設定も戻せないので確かめる。
    public static func deletingList(title: String) -> Confirmation {
        .destructive(title: "リスト“\(title)”を削除しますか？", message: "メンバーの設定も削除され、元に戻せません。", action: "削除")
    }

    // MARK: - 投稿

    /// 削除は元に戻せないので確かめる。
    public static var deleting: Confirmation {
        deleting(actor: nil)
    }

    /// - Parameter actor: ほかのアカウントとして削除するときの、そのアカウントの`@username`。見出しの初めに「〜で」と入れる。
    public static func deleting(actor: String?) -> Confirmation {
        .destructive(title: "\(actor.map { "\($0)で" } ?? "")投稿を削除しますか？", message: "削除した投稿は元に戻せません。", action: "削除")
    }

    /// 引用の取り消しは元に戻せないので確かめる。
    /// - Parameter acct: 引用した人のハンドル。
    public static func revokingQuote(by acct: String) -> Confirmation {
        .destructive(title: "@\(acct)の引用を取り消しますか？", message: "この投稿からあなたの投稿が表示されなくなり、元に戻せません。", action: "取り消す")
    }

    /// 予約の取り消しは元に戻せないので確かめる。
    public static var cancelingSchedule: Confirmation {
        .destructive(title: "予約を取り消しますか？", message: "取り消した予約は投稿されず、元に戻せません。", action: "取り消す")
    }

    /// 書きかけの投稿欄で`start`を始める前に、そのまま進むか、確かめるか、断るかを決める。
    /// 始める操作と下書きの状態の組み合わせは、ここだけで決める。画面は結果に従い、投稿欄のモデルの入口（`setReplyTarget`や`beginEditing`など）は、
    /// ここで進むと決めたものを受け付ける。別々に決めると、確かめずに進めたのにモデルが受け付けず、押しても何も起きなくなるため。
    /// 共有されたもので書き始めるときは、下書きに足すかも選ぶので、`shared(_:draft:)`で決める。
    /// - Parameter now: 編集で、投票の締め切りまでの残りを見る今の日付。
    @MainActor
    public static func starting<Thumbnail>(_ start: ComposeStart, draft: ComposeModel<Thumbnail>, now: Date) -> ComposeStartDecision {
        // 送っている間は、失敗したときに送り直せるよう下書きを残すので、どれも始められない。
        // 待てば済むので、アラートで操作を止めず、チップで伝える。
        guard !draft.isPosting else { return .waitUntilPosted }
        switch start {
        case .reply, .mention:
            return leaving(for: start, draft: draft).map { ComposeStartDecision(.confirm($0), leavesCurrentWork: true) } ?? ComposeStartDecision(.proceed)
        case .quote:
            if let leaving = leaving(for: start, draft: draft) {
                // やめると投稿欄は空に戻るので、外す添付と投票は残らない。
                return ComposeStartDecision(.confirm(leaving), leavesCurrentWork: true)
            }
            return ComposeStartDecision(quoting(draft: draft).map { .confirm($0) } ?? .proceed)
        case .edit(let status, let actor):
            return ComposeStartDecision(editing(status, draft: draft, now: now, actor: actor))
        case .redraft(let status, let actor):
            return ComposeStartDecision(.confirm(redrafting(status, draft: draft, actor: actor)))
        case .rewrite:
            return ComposeStartDecision(rewriting(draft: draft).map { .confirm($0) } ?? .proceed)
        }
    }

    /// 返信、引用、メンションを始める前に、いましていることをやめてよいか確かめる。やめなくてよければ確かめない（nil）。
    /// 予約の書き直しは、同じアカウントのままなら返信先や引用元を付け替えて続けられるので、投稿するアカウントを替えるときだけ確かめる。
    /// 予約は書いたアカウントのサーバーにあり、ほかのアカウントでは書き直せないため。
    @MainActor
    private static func leaving<Thumbnail>(for start: ComposeStart, draft: ComposeModel<Thumbnail>) -> Confirmation? {
        if let confirmation = leavingEdit(starting: start.name, draft: draft) { return confirmation }
        guard draft.rewritingSchedule != nil, start.switchesAccount else { return nil }
        return .destructive(title: "予約の書き直しをやめて\(start.name)しますか？", message: "書き直し中の内容は破棄されます。元の予約は残ります。", action: "書き直しをやめる")
    }

    /// 編集か削除して書き直している途中で返信か引用を選んだら、やめてよいか確かめる。どちらでもなければ確かめない（nil）。
    /// 返信と引用は書いた本文を残して返信先や引用元を付け替えるが、編集と書き直しの本文は元の投稿のもので、
    /// 書き直しでは返信先と引用元を変えられないため、引き継がない。
    /// - Parameter starting: 「返信」「引用」のような、始める操作の名前。
    @MainActor
    private static func leavingEdit<Thumbnail>(starting: String, draft: ComposeModel<Thumbnail>) -> Confirmation? {
        if draft.editedStatus != nil {
            return .destructive(title: "編集をやめて\(starting)しますか？", message: discardedDraftMessage(draft), action: "編集をやめる")
        }
        guard draft.redraft != nil else { return nil }
        return .destructive(title: "書き直しをやめて\(starting)しますか？", message: discardedDraftMessage(draft), action: "書き直しをやめる")
    }

    /// 削除して書き直している途中でラベルの×を押したとき、元の投稿を削除した（かもしれない）なら、捨ててよいか確かめる。
    /// 削除する前は、元の投稿が残るので確かめない（nil）。
    @MainActor
    public static func discardingRedraft<Thumbnail>(draft: ComposeModel<Thumbnail>) -> Confirmation? {
        guard draft.redraft?.mayHaveDeleted == true else { return nil }
        return .destructive(title: "書き直しをやめますか？", message: discardedDraftMessage(draft), action: "書き直しをやめる")
    }

    /// ＋の「下書きを捨てる」で、捨てると失われる書いたものがあれば確かめる。なければ確かめない（nil）。
    /// 編集や書き直しの途中なら、それをやめることを題とボタンにする。
    @MainActor
    public static func discardingDraft<Thumbnail>(draft: ComposeModel<Thumbnail>) -> Confirmation? {
        guard draft.hasWrittenContent else { return nil }
        if draft.editedStatus != nil {
            return .destructive(title: "編集をやめますか？", message: discardedDraftMessage(draft), action: "編集をやめる")
        }
        if draft.redraft != nil {
            return .destructive(title: "書き直しをやめますか？", message: discardedDraftMessage(draft), action: "書き直しをやめる")
        }
        if draft.rewritingSchedule != nil {
            return .destructive(title: "予約の書き直しをやめますか？", message: "書き直し中の内容は破棄されます。元の予約は残ります。", action: "書き直しをやめる")
        }
        return .destructive(title: "下書きを破棄しますか？", message: discardedDraftMessage(draft), action: "破棄")
    }

    /// 送ると元の投稿を削除することを、書きかけの下書きがあれば捨ててよいかも、確かめてから削除して書き直し始める。
    /// 投票の票は投票の付いた投稿でだけ、固定が外れることはプロフィールに固定している投稿でだけ書く。
    /// - Parameter actor: ほかのアカウントとして書き直すときの、そのアカウントの`@username`。見出しの初めに「〜で」と入れる。
    @MainActor
    private static func redrafting<Thumbnail>(_ status: Status, draft: ComposeModel<Thumbnail>, actor: String?) -> Confirmation {
        let discards = draft.hasWrittenContent
        let lost = ["お気に入り", "ブースト", status.poll == nil ? nil : "投票の票"].compactMap(\.self).joined(separator: "、")
        var lines: [String] = []
        if discards {
            lines.append(discardedDraftMessage(draft))
        }
        lines.append("書き直した投稿を送ると元の投稿を削除します。\(lost)はなくなり、元の投稿への返信はつながりを失います。")
        if status.pinned {
            lines.append("プロフィールへの固定も外れます。")
        }
        return .destructive(
            title: "\(actor.map { "\($0)で" } ?? "")\(discards ? "下書きを破棄して書き直しますか？" : "削除して書き直しますか？")",
            message: lines.joined(separator: "\n"),
            action: discards ? "破棄して書き直す" : "書き直す"
        )
    }

    /// 下書きに添付か投票があれば、外してよいか確かめる。なければ確かめない（nil）。
    /// Mastodonは引用に添付と投票を付けられないため。本文は残す。
    @MainActor
    private static func quoting<Thumbnail>(draft: ComposeModel<Thumbnail>) -> Confirmation? {
        guard draft.hasQuoteConflicts else { return nil }
        let removing = [draft.attachments.isEmpty ? nil : "添付ファイル", draft.poll == nil ? nil : "投票"].compactMap(\.self).joined(separator: "と")
        return .destructive(title: "\(removing)を外して引用しますか？", message: "引用する投稿には添付ファイルや投票を付けられません。書いた本文は残ります。", action: "外して引用")
    }

    /// 書きかけの下書きがあれば、捨ててよいか確かめてから、予約した投稿の書き直しを始める。なければ確かめない（nil）。
    @MainActor
    private static func rewriting<Thumbnail>(draft: ComposeModel<Thumbnail>) -> Confirmation? {
        guard draft.hasWrittenContent else { return nil }
        return .destructive(title: "下書きを破棄して書き直しますか？", message: discardedDraftMessage(draft), action: "破棄して書き直す")
    }

    /// 書きかけの下書きがあれば捨ててよいかを、投票の付いた投稿なら締め切りがずれることを、確かめてから編集を始める。
    /// 投票の締め切りが近くて編集できなければ、そのことを知らせる。
    /// 押されたあとも、聞いている間に締め切りが近づいていないかを`Status.canBeEdited(now:)`で確かめ直し、近づいていれば`RefusalText.cannotEdit`を知らせる。
    /// - Parameter actor: ほかのアカウントとして編集するときの、そのアカウントの`@username`。見出しの初めに「〜で」と入れる。
    @MainActor
    private static func editing<Thumbnail>(_ status: Status, draft: ComposeModel<Thumbnail>, now: Date, actor: String?) -> ConfirmationDecision<Proceed> {
        if let obstacle = status.editObstacle(now: now) { return .refuse(.cannotEdit(obstacle)) }
        let discards = draft.hasWrittenContent
        let hasPoll = status.poll != nil
        guard discards || hasPoll else { return .proceed }
        var lines: [String] = []
        if discards {
            lines.append(discardedDraftMessage(draft))
        }
        if hasPoll {
            lines.append("投票はそのまま残りますが、締め切りは送った時点から数え直すため少しずれます。")
        }
        return .confirm(Confirmation(
            title: "\(actor.map { "\($0)で" } ?? "")\(discards ? "下書きを破棄して編集しますか？" : "投票の付いた投稿を編集しますか？")",
            message: lines.joined(separator: "\n"),
            buttons: [.cancel, Button(discards ? "破棄して編集" : "編集", role: discards ? .destructive : .default, choice: .proceed)]
        ))
    }

    @MainActor
    private static func discardedDraftMessage<Thumbnail>(_ draft: ComposeModel<Thumbnail>) -> String {
        if draft.editedStatus != nil { return "編集中の内容は破棄されます。" }
        switch draft.redraft?.deletion {
        case .pending: return "書き直し中の内容は破棄されます。元の投稿は残ります。"
        case .uncertain: return "書き直し中の内容は破棄されます。元の投稿は削除したかもしれず、その場合は戻せません。"
        case .done: return "書き直し中の内容は破棄されます。元の投稿は削除したため戻せません。"
        case nil: return "書きかけの下書きは破棄されます。"
        }
    }
}

/// 共有拡張から受け取ったもの。
public enum SharedContent: Sendable {
    /// Safariのページのタイトル、URL、選んだ文の引用など。
    case text
    /// 画像や動画。`allImages`なら、文言で「画像」と書く。
    case media(allImages: Bool)
}

/// 共有されたものを、書きかけの下書きにどう入れるか。
public enum SharedContentChoice: Hashable, Sendable {
    /// 下書きに足す。
    case append
    /// 下書きを捨てて、新しく書く。
    case discardAndWrite
    /// 足さずに閉じる。受け取ったメディアを片付けるため、キャンセルでも選ぶ。
    case cancel
}

extension Confirmation where Choice == SharedContentChoice {
    /// 共有されたもので書き始める前に、書きかけの下書きがあれば、足すか、捨てて新しく書くかを聞く。
    /// 投稿を送っている間は、送り終えて下書きを空に戻すときに一緒に消えるので、書き始めない。
    @MainActor
    public static func shared<Thumbnail>(_ content: SharedContent, draft: ComposeModel<Thumbnail>) -> ConfirmationDecision<SharedContentChoice> {
        guard !draft.isPosting else { return .refuse(.sharedWhilePosting(content)) }
        guard draft.hasWrittenContent else { return .proceed }
        let isEditing = draft.editedStatus != nil
        let destination = switch content {
        case .text: "共有された文を\(isEditing ? "編集中の投稿" : "下書き")の後ろに追加するか"
        case .media(let allImages): "共有された\(allImages ? "画像" : "メディア")を\(isEditing ? "編集中の投稿" : "下書き")に追加するか"
        }
        return .confirm(Confirmation(
            title: isEditing ? "編集中の投稿があります" : "書きかけの下書きがあります",
            message: "\(destination)、\(isEditing ? "編集をやめて" : "下書きを破棄して")新しく書くかを選んでください。",
            buttons: [
                Button(isEditing ? "編集中の投稿に追加" : "下書きに追加", role: .default, choice: .append),
                Button(isEditing ? "編集をやめて新しく書く" : "下書きを破棄して新しく書く", role: .destructive, choice: .discardAndWrite),
                Button("キャンセル", role: .cancel, choice: .cancel),
            ]
        ))
    }
}

extension RefusalText {
    /// メニューを出してから編集を始めるまでに、投票の締め切りまで5分を切ったか、締め切ったとき。
    public static func cannotEdit(_ obstacle: Status.EditObstacle) -> RefusalText {
        switch obstacle {
        case .pollClosed: RefusalText(title: "編集できません", message: "投票を締め切ったため、この投稿は編集できません。")
        case .pollTooClose: RefusalText(title: "編集できません", message: "投票の締め切りまで5分を切ったため、この投稿は編集できません。")
        }
    }

    /// 共有されたメディアを添付できなかったときの題。
    static let sharedMediaFailureTitle = "共有されたメディアを添付できませんでした"

    /// 共有拡張が受け取ったファイルが、もう消えていたとき。同じURLを開き直したときなど。
    public static let sharedMediaGone = RefusalText(title: sharedMediaFailureTitle, message: "もう一度共有してください。")

    /// 書き始めてサーバーの設定を読み終えても、下書きに共有されたメディアを足せなかったとき。足せない理由を出す。
    @MainActor
    public static func sharedMediaUnattachable<Thumbnail>(draft: ComposeModel<Thumbnail>) -> RefusalText {
        mediaUnattachable(draft: draft, title: sharedMediaFailureTitle, retry: "もう一度共有してください。")
    }

    /// 画面にドロップしたメディアを、書き始めてサーバーの設定を読み終えても、下書きに足せなかったとき。足せない理由を出す。
    @MainActor
    public static func droppedMediaUnattachable<Thumbnail>(draft: ComposeModel<Thumbnail>) -> RefusalText {
        mediaUnattachable(draft: draft, title: "ドロップしたメディアを添付できませんでした", retry: "もう一度ドロップしてください。")
    }

    @MainActor
    private static func mediaUnattachable<Thumbnail>(draft: ComposeModel<Thumbnail>, title: String, retry: String) -> RefusalText {
        let message = if draft.isPosting {
            "投稿を送っている間は添付できません。送り終えてから\(retry)"
        } else if draft.isQuoting {
            "引用する投稿には添付できません。引用をやめてから\(retry)"
        } else if draft.poll != nil {
            "投票の付いた投稿には添付できません。投票を外してから\(retry)"
        } else {
            "サーバーの設定を読み込めませんでした。\(retry)"
        }
        return RefusalText(title: title, message: message)
    }

    /// 投稿を送っている間に、共有されたものを受け取ったとき。
    public static func sharedWhilePosting(_ content: SharedContent) -> RefusalText {
        switch content {
        case .text:
            RefusalText(title: "共有された文で書き始められませんでした", message: "投稿を送っている間は書き始められません。送り終えてからもう一度共有してください。")
        case .media:
            RefusalText(title: sharedMediaFailureTitle, message: "投稿を送っている間は添付できません。送り終えてからもう一度共有してください。")
        }
    }

    /// 読み直して確かめたら、引用できない投稿だったとき。
    /// - Parameter followersOnly: フォロワーだけが引用できる投稿。そうでなければ、投稿者が引用を許していない。
    public static func quoteDenied(followersOnly: Bool) -> RefusalText {
        RefusalText(title: "この投稿は引用できません", message: followersOnly ? "フォロワーだけが引用できる投稿です。" : "投稿者が引用を許していない投稿です。")
    }
}

extension FollowState {
    /// プロフィールのフォローのボタンを押したときに送る変更。フォローしていなければフォローし、
    /// フォローしているか承認を待っていれば、外すか取り消す。ボタンを出さない状態ではnil。
    public var toggleChange: UserRelationChange? {
        switch self {
        case .notFollowing: .follow
        case .following: .unfollow
        case .requested: .cancelFollowRequest
        case .myself, .unknown, .loadFailed, .blocked: nil
        }
    }
}
