/// 投稿欄の本文の上に出すラベル。返信なら返信先、引用なら引用元、編集なら編集していること（返信の編集なら返信先も）を書く。
/// 編集では返信先を変えられないので、返信先のラベルは出さず、編集のラベルにまとめる。返信、引用、編集で1つのラベルを使う。
public struct ComposeContextChip: Equatable, Sendable {
    public let title: String
    public let symbolName: String
    /// ラベルを押すと何が起きるかの、読み上げのヒント。押しても見せるものがなければ空。
    public let hint: String
    /// ラベルを外すボタンの名前。
    public let clearLabel: String
}

extension ComposeModel {
    /// 本文の上に出すラベル。新しい投稿を書いていればnil。
    public var contextChip: ComposeContextChip? {
        if let title = redraftChipTitle {
            // 削除したあとは、押しても見せる元の投稿がない。
            let deleted = redraft?.mayHaveDeleted == true
            return ComposeContextChip(title: title, symbolName: "square.and.pencil", hint: deleted ? "" : "タイムラインの元の投稿を表示します。", clearLabel: "書き直しをやめる")
        }
        if let title = rewriteChipTitle {
            return ComposeContextChip(title: title, symbolName: "pencil", hint: "予約投稿を表示します。", clearLabel: "書き直しをやめる")
        }
        if let title = editChipTitle {
            return ComposeContextChip(title: title, symbolName: "pencil", hint: "タイムラインの編集している投稿を表示します。", clearLabel: "編集をやめる")
        }
        if let quoteTarget {
            let acct = "@\(quoteTarget.displayed.account.acct)"
            return ComposeContextChip(title: "\(acct)の投稿を引用", symbolName: "quote.bubble.fill", hint: "タイムラインの引用元の投稿を表示します。", clearLabel: "引用をやめる")
        }
        guard let replyTo else { return nil }
        return ComposeContextChip(title: ReplyLabel.toAccount(acct: replyTo.displayed.account.acct).title, symbolName: "arrowshape.turn.up.left.fill", hint: "タイムラインの返信先の投稿を表示します。", clearLabel: "返信をやめる")
    }

    /// 投稿ボタンの名前。予約している間は予約に、メディアの準備を待っている間は、押すと待つのをやめることが分かる名前にする。
    public var sendButtonTitle: String {
        switch (isWaitingForMedia, scheduledAt != nil) {
        case (true, true): "予約をやめる"
        case (true, false): "投稿をやめる"
        case (false, true): "予約"
        case (false, false): "投稿"
        }
    }

    /// 残りの文字数の読み上げ。
    public var remainingCharactersLabel: String {
        "残り\(remainingCharacters)文字"
    }
}

extension ComposeAttachmentStatus {
    /// 添付の状態の文言。付けられる状態ではnil。ビューアのチップ（`Notice.draftStatus`）と同じ文言にする。
    public var title: String? {
        switch self {
        case .exporting: "書き出し中"
        case .uploading: "アップロード中"
        case .processing: "サーバーで処理中"
        case .ready: nil
        case .sendingDescription: "代替テキストを送信中"
        case .failed: "アップロードできませんでした"
        case .descriptionFailed: "代替テキストを送信できませんでした"
        }
    }

    /// 進み具合を割合で出す状態か。
    public var showsProgress: Bool {
        self == .exporting || self == .uploading
    }

    /// 添付の読み上げの値。送っている間は、進み具合の割合を続ける。
    public func accessibilityValue(progress: Double?) -> String? {
        guard let title else { return nil }
        guard showsProgress, let percent = progress.flatMap(Notice.percentText(of:)) else { return title }
        return "\(title)、\(percent)"
    }
}

/// 投稿欄と、投稿欄から開く画面（補完の候補、投票の欄、絵文字のパレット、画像の切り抜き、投稿の言語）の文言。
public enum ComposeTexts {
    public static let cancel = "キャンセル"
    public static let done = "完了"
    public static let retry = "再試行"
    public static let delete = "削除"

    /// 添付の帯のサムネイルの操作と読み上げ。
    public enum Attachment {
        public static let moveToFirst = "先頭へ移動"
        public static let moveBackward = "前へ移動"
        public static let moveForward = "後ろへ移動"
        public static let moveToLast = "末尾へ移動"
        public static let editHint = "開いて代替テキストを編集できます。"

        /// サムネイルの読み上げ。種類、閲覧注意か、代替テキストの順に、空でないものを読む。種類が分からなければ「メディア」と読む。
        public static func accessibilityLabel(kind: MediaAttachment.Kind?, isSensitive: Bool, description: String) -> String {
            [kind?.displayName ?? "メディア", isSensitive ? MediaCover.title(of: .sensitive) : "", description].filter { !$0.isEmpty }.joined(separator: "、")
        }
    }
}
