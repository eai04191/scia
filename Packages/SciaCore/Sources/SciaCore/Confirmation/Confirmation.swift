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
    public static func relationChange(_ change: UserRelationChange, acct: String) -> Confirmation? {
        switch change {
        case .unfollow:
            .destructive(title: "@\(acct)のフォローを外しますか？", message: nil, action: "フォローを外す")
        case .cancelFollowRequest:
            .destructive(title: "@\(acct)へのフォローのリクエストを取り消しますか？", message: nil, action: "リクエストを取り消す")
        case .block:
            .destructive(title: "@\(acct)をブロックしますか？", message: "相手の投稿と通知が表示されなくなり、お互いのフォローが外れます。", action: "ブロック")
        case .follow, .showReblogs, .notify, .mute, .unmute, .unblock:
            nil
        }
    }

    // MARK: - 投稿

    /// 削除は元に戻せないので確かめる。
    public static var deleting: Confirmation {
        .destructive(title: "投稿を削除しますか？", message: "削除した投稿は元に戻せません。", action: "削除")
    }

    /// 予約の取り消しは元に戻せないので確かめる。
    public static var cancelingSchedule: Confirmation {
        .destructive(title: "予約を取り消しますか？", message: "取り消した予約は投稿されず、元に戻せません。", action: "取り消す")
    }

    /// 編集している途中で返信か引用を選んだら、編集をやめてよいか確かめる。編集でなければ確かめない（nil）。
    /// 返信と引用は書いた本文を残して返信先や引用元を付け替えるが、編集の本文は元の投稿のものなので、引き継がない。
    /// - Parameter title: 「編集をやめて返信しますか？」のような、始める操作に合わせた題。
    @MainActor
    public static func leavingEdit<Thumbnail>(title: String, draft: ComposeModel<Thumbnail>) -> Confirmation? {
        guard draft.editedStatus != nil else { return nil }
        return .destructive(title: title, message: "編集中の内容は消えます。", action: "編集をやめる")
    }

    /// 下書きに添付か投票があれば、外してよいか確かめる。なければ確かめない（nil）。
    /// Mastodonは引用に添付と投票を付けられないため。本文は残す。
    @MainActor
    public static func quoting<Thumbnail>(draft: ComposeModel<Thumbnail>) -> Confirmation? {
        guard draft.hasQuoteConflicts else { return nil }
        let removing = [draft.attachments.isEmpty ? nil : "添付ファイル", draft.poll == nil ? nil : "投票"].compactMap(\.self).joined(separator: "と")
        return .destructive(title: "\(removing)を外して引用しますか？", message: "引用する投稿には、添付ファイルや投票を付けられません。書いた本文は残ります。", action: "外して引用")
    }

    /// 書きかけの下書きがあれば、捨ててよいか確かめてから、予約した投稿の書き直しを始める。なければ確かめない（nil）。
    @MainActor
    public static func rewriting<Thumbnail>(draft: ComposeModel<Thumbnail>) -> Confirmation? {
        guard draft.hasWrittenContent else { return nil }
        return .destructive(title: "下書きを捨てて書き直しますか？", message: discardedDraftMessage(draft), action: "捨てて書き直す")
    }

    /// 書きかけの下書きがあれば捨ててよいかを、投票の付いた投稿なら締め切りがずれることを、確かめてから編集を始める。
    /// 投票の締め切りが近くて編集できなければ、そのことを知らせる。
    /// 押されたあとも、聞いている間に締め切りが近づいていないかを`Status.canBeEdited(now:)`で確かめ直し、近づいていれば`RefusalText.pollTooClose`を知らせる。
    @MainActor
    public static func editing<Thumbnail>(_ status: Status, draft: ComposeModel<Thumbnail>, now: Date) -> ConfirmationDecision<Proceed> {
        guard status.canBeEdited(now: now) else { return .refuse(.pollTooClose) }
        let discards = draft.hasWrittenContent
        let hasPoll = status.poll != nil
        guard discards || hasPoll else { return .proceed }
        var lines: [String] = []
        if discards {
            lines.append(discardedDraftMessage(draft))
        }
        if hasPoll {
            lines.append("投票はそのまま残りますが、締め切りは送った時点から数え直すため、少しずれます。")
        }
        return .confirm(Confirmation(
            title: discards ? "下書きを捨てて編集しますか？" : "投票の付いた投稿を編集しますか？",
            message: lines.joined(separator: "\n"),
            buttons: [.cancel, Button(discards ? "捨てて編集" : "編集", role: discards ? .destructive : .default, choice: .proceed)]
        ))
    }

    @MainActor
    private static func discardedDraftMessage<Thumbnail>(_ draft: ComposeModel<Thumbnail>) -> String {
        draft.editedStatus != nil ? "編集中の内容は消えます。" : "書きかけの下書きは消えます。"
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
        case .text: "共有された文を、\(isEditing ? "編集中の投稿" : "下書き")の後ろに足すか"
        case .media(let allImages): "共有された\(allImages ? "画像" : "メディア")を、\(isEditing ? "編集中の投稿" : "下書き")に足すか"
        }
        return .confirm(Confirmation(
            title: isEditing ? "編集中の投稿があります" : "書きかけの下書きがあります",
            message: "\(destination)、\(isEditing ? "編集をやめて" : "下書きを捨てて")新しく書くかを選んでください。",
            buttons: [
                Button(isEditing ? "編集中の投稿に足す" : "下書きに足す", role: .default, choice: .append),
                Button(isEditing ? "編集をやめて新しく書く" : "下書きを捨てて新しく書く", role: .destructive, choice: .discardAndWrite),
                Button("キャンセル", role: .cancel, choice: .cancel),
            ]
        ))
    }
}

extension RefusalText {
    /// メニューを出してから編集を始めるまでに、投票の締め切りまで5分を切ったとき。
    public static let pollTooClose = RefusalText(title: "編集できません", message: "投票の締め切りまで5分を切ったため、この投稿は編集できません。")

    /// 共有されたメディアを添付できなかったときの題。
    static let sharedMediaFailureTitle = "共有されたメディアを添付できませんでした"

    /// 共有拡張が受け取ったファイルが、もう消えていたとき。同じURLを開き直したときなど。
    public static let sharedMediaGone = RefusalText(title: sharedMediaFailureTitle, message: "もう一度共有してください。")

    /// 書き始めてサーバーの設定を読み終えても、下書きに共有されたメディアを足せなかったとき。足せない理由を出す。
    @MainActor
    public static func sharedMediaUnattachable<Thumbnail>(draft: ComposeModel<Thumbnail>) -> RefusalText {
        let message = if draft.isPosting {
            sharedWhilePosting(.media(allImages: false)).message
        } else if draft.quoteTarget != nil {
            "引用する投稿には添付できません。引用をやめてから、もう一度共有してください。"
        } else if draft.poll != nil {
            "投票の付いた投稿には添付できません。投票を外してから、もう一度共有してください。"
        } else {
            "サーバーの設定を読み込めませんでした。もう一度共有してください。"
        }
        return RefusalText(title: sharedMediaFailureTitle, message: message)
    }

    /// 投稿を送っている間に、共有されたものを受け取ったとき。
    public static func sharedWhilePosting(_ content: SharedContent) -> RefusalText {
        switch content {
        case .text:
            RefusalText(title: "共有された文で書き始められませんでした", message: "投稿を送っている間は書き始められません。送り終えてから、もう一度共有してください。")
        case .media:
            RefusalText(title: sharedMediaFailureTitle, message: "投稿を送っている間は添付できません。送り終えてから、もう一度共有してください。")
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
