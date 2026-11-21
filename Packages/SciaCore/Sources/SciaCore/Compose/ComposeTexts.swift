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

    /// 書いていないときの1行の読み上げのラベル。
    public static let composerLabel = "投稿欄"
    /// 本文の入力欄の案内。
    public static let textPlaceholder = "いまどうしてる？"
    public static let textLabel = "本文"
    public static let send = "投稿"
    /// ボタンの並びに入らない項目を出す＋のボタン。
    public static let add = "追加"
    public static let collapse = "元の大きさに戻す"
    /// 絵文字のパレットやメディアのピッカーを出している間に、同じ項目の代わりに出す、閉じてキーボードに戻る項目。
    public static let backToKeyboard = "キーボードに戻る"
    public static let crop = "トリミング"
    /// 音声のある動画の音声を消して送る項目。Mastodonは音声のない動画をGIFとして扱うので、「音声を消す」ではなく、送ったあとの姿で書く。
    public static let sendAsGIF = "GIFとして送る"

    /// 広げるボタンの名前。
    public static func expandToggle(isExpanded: Bool) -> String {
        isExpanded ? collapse : ComposeToolItem.expand.title
    }

    /// 書いているほかのアカウントの行を消して、今のアカウントに戻すボタン。
    public static let switchToCurrentAccount = "今のアカウントで投稿する"
    /// 編集や書き直しの間に、投稿するアカウントのメニューに添える、替えられない理由。
    public static let accountLocked = "編集や書き直しの間は替えられません"

    /// 書いているほかのアカウントの行。
    public static func writingAs(username: String) -> String {
        "@\(username)で投稿"
    }

    /// 押せない項目に添える理由。
    public static let unavailableWithQuote = "引用とは一緒に付けられません"
    public static let unavailableWithPoll = "投票とは一緒に付けられません"
    public static let unavailableWithMedia = "メディアとは一緒に付けられません"
    public static let unavailableInEdit = "編集では付けられません"
    /// リンクにタイトルを付ける項目の、本文にURLがないときの理由。
    public static let noURLInText = "本文にURLがありません"

    /// 添付があるときに、注意書きの項目に添える説明。
    public static let spoilerMarksMediaSensitive = "添付も閲覧注意にします"
    /// 閲覧注意にしているときの、注意書きのボタンの読み上げの値。
    public static let spoilerSensitiveValue = "添付も閲覧注意"

    /// 注意書きの欄の案内。添付があると、空の注意書きでも閲覧注意になるので、空のまま出している意味が分かるよう、案内を変える。
    public static func spoilerPlaceholder(hasAttachments: Bool) -> String {
        hasAttachments ? "注意書き（空なら閲覧注意だけ）" : ComposeToolItem.spoiler.title
    }

    /// 注意書きの欄を外すボタン。
    public static func spoilerClearLabel(isSensitive: Bool) -> String {
        isSensitive ? "注意書きと閲覧注意を外す" : "注意書きを外す"
    }

    /// 公開範囲のメニューの中の、引用できる人の見出し。公開範囲で決まっていて選べなければ、そう添える。
    public static func quotePolicyMenuTitle(isFixed: Bool) -> String {
        isFixed ? "引用できる人（この公開範囲では選べません）" : "引用できる人"
    }

    /// 公開範囲や＋のボタンの読み上げの値に続ける、引用できる人。
    public static func quotePolicyValue(_ title: String) -> String {
        "引用できる人: \(title)"
    }

    /// ＋のボタンの読み上げの値に入れる、選んでいる言語。
    public static func languageValue(_ name: String) -> String {
        "言語: \(name)"
    }

    public static let scheduleDate = "予約の日時"
    public static let cancelSchedule = "予約をやめる"

    /// 予約の行。日時を押せるラベルにし、続く文を添えるので、日時の範囲を添える。
    public static func scheduledPost(date: String) -> PostTexts.EmphasizedText {
        let text = "\(date)に投稿"
        let start = text.range(of: date)?.lowerBound ?? text.startIndex
        return PostTexts.EmphasizedText(text: text, emphasis: start..<text.index(start, offsetBy: date.count))
    }

    /// 送れなかったときのアラートの題。
    public static func postFailedTitle(isScheduled: Bool) -> String {
        isScheduled ? "予約できませんでした" : "投稿できませんでした"
    }

    /// 書いていないときの1行の読み上げの値。ラベルとサムネイルは文字を出さないので、書いているときのラベルと同じ文と、添付の数を読む。
    /// - Parameters:
    ///   - chipTitle: 本文の上のラベル（返信先など）。
    ///   - onlyImages: 添付がどれも画像か。
    ///   - hasFailedAttachment: 送れなかった添付があるか。
    ///   - scheduledDate: 予約している日時の読み上げ。予約していなければnil。
    ///   - text: 本文。
    public static func restAccessibilityValue(chipTitle: String?, attachmentCount: Int, onlyImages: Bool, hasFailedAttachment: Bool, scheduledDate: String?, text: String, isPosting: Bool) -> String {
        var parts: [String] = []
        if let chipTitle {
            parts.append(chipTitle)
        }
        if attachmentCount > 0 {
            parts.append(onlyImages ? "画像\(attachmentCount)枚を添付" : "メディア\(attachmentCount)件を添付")
            if hasFailedAttachment {
                parts.append("送信できなかった添付があります")
            }
        }
        if let scheduledDate {
            parts.append("\(scheduledDate)に予約")
        }
        parts.append(text)
        if isPosting {
            parts.append(scheduledDate != nil ? "予約中" : "投稿中")
        }
        return parts.joined(separator: "、")
    }

    /// 添付の帯のサムネイルの操作と読み上げ。
    public enum Attachment {
        public static let moveToFirst = "先頭へ移動"
        public static let moveBackward = "前へ移動"
        public static let moveForward = "後ろへ移動"
        public static let moveToLast = "末尾へ移動"
        public static let editHint = "開いて代替テキストを編集できます。"
        public static let markSensitive = "閲覧注意にする"
        public static let unmarkSensitive = "閲覧注意を外す"
        /// 注意書きを書いているときの、閲覧注意を外す項目に添える理由。
        public static let sensitiveLockedBySpoiler = "注意書きがあると外せません"

        /// サムネイルの読み上げ。種類、閲覧注意か、代替テキストの順に、空でないものを読む。種類が分からなければ「メディア」と読む。
        public static func accessibilityLabel(kind: MediaAttachment.Kind?, isSensitive: Bool, description: String) -> String {
            [kind?.displayName ?? "メディア", isSensitive ? MediaCover.title(of: .sensitive) : "", description].filter { !$0.isEmpty }.joined(separator: "、")
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

extension ComposeTexts {
    /// 添付の画像を切り抜く画面。
    public enum Crop {
        public static let cropArea = "切り抜く範囲"
        public static let rotate = "回転"
        public static let reset = "リセット"
        public static let aspect = "縦横比"
        /// 縦横比を決めない選び方。
        public static let freeAspect = "自由"
        /// 回したあとの画像の比率の選び方。
        public static let originalAspect = "元の比率"
    }
}

/// 言語を選ぶシートで選ぶ対象。アカウントの既定を選ぶときは、題と、言語を決めない行の文言を変える。
public enum PostingLanguagePurpose: Sendable {
    /// 書いている投稿の言語。
    case post
    /// アカウントの既定の言語（docs/account-screen.mdの「投稿のデフォルト」）。
    case accountDefault

    /// シートの題。
    public var title: String {
        switch self {
        case .post: "投稿の言語"
        case .accountDefault: "言語"
        }
    }

    /// まとまりの見出し。
    public func sectionTitle(of kind: PostingLanguageSection.Kind) -> String {
        switch (kind, self) {
        case (.defaultLanguage, .post): "アカウントのデフォルト"
        case (.defaultLanguage, .accountDefault): "指定なし"
        case (.recent, .post): "最近選んだ言語"
        case (.recent, .accountDefault): "候補"
        case (.all, _): "すべての言語"
        }
    }

    /// 言語を決めない行の、名前の下に出す説明。
    public var serverDecidesNote: String {
        switch self {
        case .post: "デフォルトの言語が設定されていないため、サーバーが決めます"
        case .accountDefault: "言語を指定せず、投稿するときにサーバーが決めます"
        }
    }
}

extension ComposeTexts {
    /// 言語を選ぶシートと、投稿欄の言語のボタン。
    public enum Language {
        public static let searchPrompt = "言語の名前"
        public static let loadFailed = "言語のリストを読み込めませんでした"
        /// 言語を決めず、サーバーに任せるときの名前。
        public static let serverDecides = "サーバーに任せる"
    }
}
