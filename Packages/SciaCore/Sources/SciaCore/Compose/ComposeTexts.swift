import Foundation

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

    /// 補完の候補のリスト。
    public enum Completion {
        public static let listLabel = "補完の候補"
        public static let failed = "候補を読み込めませんでした"
        public static let loading = "候補を探しています"

        /// 読み込めなかった行の読み上げ。
        public static func failedAccessibilityLabel(message: String) -> String {
            "\(failed)。\(message)"
        }

        /// 手元から出した人の候補の、2段目の文。ハンドルに続けて、どこから出した人かを添える。
        /// ハンドルは長ければ切り、添えた理由は切らずに見せるため、ハンドルの範囲を添える。
        public static func localAccountSubtitle(acct: String, source: LocalMentionSource) -> PostTexts.EmphasizedText {
            let handle = "@\(acct)"
            let text = "\(handle)・\(source.title)"
            let start = text.range(of: handle)?.lowerBound ?? text.startIndex
            return PostTexts.EmphasizedText(text: text, emphasis: start..<text.index(start, offsetBy: handle.count))
        }

        /// ハッシュタグの候補の、最近の投稿の数。
        public static func recentUses(_ count: Int) -> String {
            "最近の投稿\(count.formatted())件"
        }

        /// ハッシュタグの候補の読み上げ。自分のタグなら、出した理由を続ける。
        public static func hashtagAccessibilityLabel(name: String, note: String? = nil) -> String {
            note.map { "ハッシュタグ \(name)、\($0)" } ?? "ハッシュタグ \(name)"
        }

        /// 絵文字の候補の読み上げ。カスタム絵文字は短縮名、Unicodeの絵文字は名前を渡す。
        public static func emojiAccessibilityLabel(name: String) -> String {
            "絵文字 \(name)"
        }
    }

    /// 投稿欄の投票の欄。
    public enum Poll {
        public static let optionsLabel = "投票の選択肢"
        public static let optionsHint = "開いて選択肢を書きます。"
        /// 選択肢を1つも書いていないときに、折りたたんだ1行に出す案内。
        public static let writeOptions = "選択肢を書く"
        /// 選択肢を1つも書いていないときの、折りたたんだ1行の読み上げの値。
        public static let noOptionsValue = "まだ書いていません"

        /// 選択肢の欄の案内。`index`は0から数える。3つ目からは、書くと次の欄が増えることが分かるよう、足す欄として案内する。
        public static func optionPlaceholder(index: Int) -> String {
            index < 2 ? optionLabel(index: index) : "選択肢を追加"
        }

        /// 選択肢の欄の読み上げ。`index`は0から数える。
        public static func optionLabel(index: Int) -> String {
            "選択肢\(index + 1)"
        }

        public static let expiry = "締め切り"
        public static let choiceLabel = "選び方"
        public static let resultsLabel = "結果"
        public static let remove = "投票を外す"

        /// 選び方のボタンの文言。`short`なら、設定の行の幅に合わせて縮めた文言にする。
        public static func multipleTitle(_ multiple: Bool, short: Bool = false) -> String {
            switch (multiple, short) {
            case (false, false): "1つ選ぶ"
            case (true, false): "複数選ぶ"
            case (false, true): "1つ"
            case (true, true): "複数"
            }
        }

        /// 結果を見せるかのボタンの文言。`short`なら、設定の行の幅に合わせて縮めた文言にする。
        public static func hidesTotalsTitle(_ hidesTotals: Bool, short: Bool = false) -> String {
            switch (hidesTotals, short) {
            case (false, false): "結果を表示"
            case (true, false): "結果を隠す"
            case (false, true): "表示"
            case (true, true): "隠す"
            }
        }

        /// 結果を見せるかのボタンを押すと何が起きるかの、読み上げのヒント。
        public static func hidesTotalsHint(_ hidesTotals: Bool) -> String {
            hidesTotals ? "投票した人に票数を表示します。" : "締め切るまで票数を隠します。"
        }
    }
}

extension LocalMentionSource {
    /// 検索の結果より上に出る理由が分かるよう、候補に添える、どこから出した人か。
    public var title: String {
        switch self {
        case .reply: "返信先"
        case .recent: "前にメンションした人"
        }
    }
}

extension OwnHashtag.Source {
    /// 検索の結果より上に出る理由が分かるよう、候補に添える、自分のタグであること。
    public var title: String {
        switch self {
        case .featured(let count): "プロフィールのタグ・投稿\(count.formatted())件"
        case .recent: "最近使ったタグ"
        }
    }
}

extension CompletionKind {
    /// 一致する候補がないときに出す文言。
    public var emptyTitle: String {
        switch self {
        case .mention: "一致するアカウントがありません"
        case .hashtag: "一致するハッシュタグがありません"
        case .emoji: "一致する絵文字がありません"
        }
    }
}

extension ComposeTexts {
    /// 添付の画像を切り抜く画面。
    public enum Crop {
        public static let cropArea = "切り抜く範囲"
        public static let cropAreaHint = "上下にスワイプして拡大と縮小をします。範囲は操作で動かします。"
        public static let rotate = "回転"
        public static let reset = "リセット"
        public static let aspect = "縦横比"
        /// 縦横比を決めない選び方。
        public static let freeAspect = "自由"
        /// 回したあとの画像の比率の選び方。
        public static let originalAspect = "元の比率"
    }

    /// 絵文字のパレット。
    public enum EmojiPalette {
        public static let noEmojis = "並べる絵文字がありません"
        public static let noResults = "見つかりません"
        public static let search = "絵文字を検索"
        public static let loadingCustomEmojis = "カスタム絵文字を読み込んでいます"
    }
}

extension StandardEmojiGroup {
    /// まとまりの名前（`Tools/build-emoji-data.py`の`GROUP_TITLES`）と、まとまりのボタンのSF Symbolsの名前。
    private static let symbolNames: [String: String] = [
        "顔と感情": "face.smiling",
        "人と体": "hand.raised",
        "動物と自然": "pawprint",
        "食べ物と飲み物": "fork.knife",
        "旅行と場所": "car",
        "活動": "soccerball",
        "物": "lightbulb",
        "記号": "number",
        "旗": "flag",
    ]

    /// まとまりのボタンのSF Symbolsの名前。表にない名前ならnil。
    public static func symbolName(forTitle title: String) -> String? {
        symbolNames[title]
    }
}
