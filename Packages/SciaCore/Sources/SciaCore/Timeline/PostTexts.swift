import Foundation

/// 投稿と通知の行に出す文言。どのUIも同じ文言で出すため、行を描く側では書かない。
/// 通知の文は`NotificationAppearance.phrase`、投票の票数と期限は`PollDisplay.summary`、一覧の空と終わりの文は`TimelineTexts`にある。
public enum PostTexts {
    /// 固定された投稿の行の上に出すラベル。プロフィールの固定された投稿の棚の見出しにも使う。
    public static let pinned = "固定された投稿"

    /// ブーストした人の行の読み上げ。
    public static func boosted(by name: String) -> String {
        "\(name)がブースト"
    }

    /// 行の高さを測るためだけに組む1行の文字で、画面には出さない。日本語の代わりの書体の行の高さも測るため、日本語の文字を入れる。
    /// 訳すときも訳さない。
    public static let lineHeightSample = "あA"

    /// 長い本文を切ったときに、末尾に出すボタン。
    public static let readMore = "続きを読む"

    /// 注意書きの読み上げで、注意書きの文の前に読む語。
    public static let contentWarningLabel = "注意書き"

    /// 注意書きのボックスの開閉のボタン。
    public static func contentWarningToggle(isCollapsed: Bool) -> String {
        isCollapsed ? "本文を表示" : "本文を隠す"
    }

    /// フィルターの警告のボックスの開閉のボタン。本文だけでなく添付ファイルやリンクカードも隠すため、本文に限らない言い方にする。
    public static func filterWarningToggle(isCollapsed: Bool) -> String {
        isCollapsed ? "投稿を表示" : "投稿を隠す"
    }

    /// 一部を目立たせて描く文。文を丸ごと持ち、目立たせる範囲を添える。言語で語順が変わっても、描く側は範囲に色を付けるだけで済む。
    public struct EmphasizedText: Equatable, Sendable {
        public let text: String
        /// 目立たせる部分。
        public let emphasis: Range<String.Index>
        /// 並べたアイテムの区切りの範囲。画面では境界線に置き換えて描く。
        public var separators: [Range<String.Index>] = []
    }

    /// フィルターの警告と、フィルターでぼかした添付ファイルに出す文。一致したフィルターの名前を目立たせる。
    public static func filterWarning(titles: [String]) -> EmphasizedText {
        let names = TextLists.items(titles)
        let prefix = "フィルター: "
        let text = prefix + names.text
        let offset = prefix.utf16.count
        let separators = names.separators.map { range in
            TextLists.range(
                utf16Offset: offset + names.text.utf16.distance(from: names.text.utf16.startIndex, to: range.lowerBound),
                length: names.text.utf16.distance(from: range.lowerBound, to: range.upperBound),
                in: text
            )
        }
        let start = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        return EmphasizedText(text: text, emphasis: start..<text.endIndex, separators: separators)
    }

    /// フィルターの警告の読み上げ。
    public static func filterWarningSpoken(titles: [String]) -> String {
        "フィルター: \(TextLists.joined(titles))"
    }

    /// 自分の投稿が、自分のフィルターに一致していることを示す1行。
    public static func ownFilterNote(titles: [String]) -> String {
        "フィルター" + titles.map { "“\($0)”" }.joined() + "に一致"
    }

    /// ぼかした添付ファイルの、理由の下に出す文言。
    public static let mediaCoverHint = "タップして表示"

    /// ぼかした添付ファイルの読み上げ。
    public static func mediaCoverAccessibilityLabel(_ cover: MediaCover?) -> String {
        "\(MediaCover.spokenTitle(of: cover))、\(mediaCoverHint)"
    }

    /// まとめた通知で、最初の人の名前に続けて出す、ほかの人の数。`count`は最初の人を除いた数。
    public static func otherAccounts(count: Int) -> String {
        "ほか\(count.formatted())人"
    }

    /// 引用元のカードの中で、引用元に投票があることを示す1行。
    public static let quotedPollNote = "投票"
    /// 引用元のカードの中で、引用元がさらに引用していることを示す、選択できる1行。
    public static let nestedQuoteNote = "引用した投稿があります"
    /// お気に入りやブーストの通知で再掲する投稿が、引用のある投稿であることを示す1行。
    public static let quoteNote = "引用した投稿"
    /// ブロックかミュートしている人の引用元を、選択して開けることを示す文言。理由の下に出す。
    public static let revealQuote = "引用元を表示"
    /// 引用元がフィルターの「隠す」に一致したときに、カードの代わりに出す1行。
    public static let quoteFiltered = "フィルターで隠しました"

    /// アイコンや名前のタップで開くプロフィールを、VoiceOverで開く操作の名前。
    public static func openProfile(name: String) -> String {
        "\(name)のプロフィール"
    }

    /// 読み上げる時刻。アイコンは読まず、編集、翻訳、公開範囲を言葉にして前に付ける。
    /// - Parameter time: 投稿した時刻の読み上げ。
    public static func timeAccessibilityText(_ time: String, isEdited: Bool, isTranslated: Bool, isTranslating: Bool, visibility: Status.Visibility) -> String {
        var text = time
        if isEdited {
            text = "編集済み、\(text)"
        }
        if isTranslated {
            text = "翻訳済み、\(text)"
        } else if isTranslating {
            text = "翻訳中、\(text)"
        }
        if visibility != .public {
            text = "\(VisibilityOption(visibility).title)、\(text)"
        }
        return text
    }

    /// 添付ファイルのグリッドで、並べきれずに隠した数の読み上げ。
    public static func hiddenMediaCount(_ count: Int) -> String {
        "ほか\(count)件"
    }

    /// 添付ファイルの読み上げで、種類が分からないときの名前。
    public static let unknownMediaKind = "メディア"

    /// リンクカードの読み上げ。空の部分は読まない。
    /// - Parameter title: ページの題。題がURLのときはnilにして読まない。
    public static func linkCardAccessibilityLabel(title: String?, site: String?) -> String {
        ["リンク", title, site].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "、")
    }

    /// リンクカードの閲覧注意でぼかした画像を、VoiceOverで表示する操作の名前。
    public static let revealSensitiveLinkImage = "閲覧注意の画像を表示"
    /// リンクカードの画像を、VoiceOverで開く操作の名前。
    public static let openLinkImage = "画像を開く"
    /// Xの投稿のカードを、VoiceOverで開く操作の名前。
    public static let openXPost = "Xの投稿を開く"
    /// 引用元のカードを、VoiceOverで開く操作の名前。
    public static let openQuotedPost = "引用元の投稿を開く"

    /// アクションバーのグループの読み上げ。
    public static let actionBar = "アクションバー"

    /// アクションバーのボタンの、状態と数の読み上げ。どちらもなければ空。
    public static func actionBarButtonValue(isOn: Bool, count: Int?) -> String {
        [isOn ? "済み" : nil, count.map { "\($0.formatted())件" }].compactMap(\.self).joined(separator: "、")
    }

    /// お気に入りやブーストで光っている投稿の、名前や本文に続けて読む状態。どちらもしていなければnil。
    public static func reactionGlowAccessibilityText(isReblogged: Bool, isFavourited: Bool) -> String? {
        let parts = [isReblogged ? "ブースト済み" : nil, isFavourited ? "お気に入り済み" : nil].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }

    /// 絵文字のリアクションのボタンの読み上げ。
    public static func reactionAccessibilityLabel(name: String, count: Int) -> String {
        "\(name) \(count.formatted())件"
    }

    /// 自分がしたリアクションのボタンの、状態の読み上げ。
    public static let ownReaction = "リアクション済み"
    /// リアクションを足すボタンの読み上げ。
    public static let addReaction = "リアクションを追加"

    /// 保留中の通知の行で、保留している通知の件数。
    public static func notificationRequestCount(_ count: Int) -> String {
        "通知\(count.formatted())件"
    }

    /// まとめた通知の行の「ほかN人」を、VoiceOverで開く操作の名前。
    public static let openGroupAccounts = "通知を送った人のリスト"

    /// 通知の行の、誰が何をしたかの文。文を丸ごと持ち、名前、ほかの人の数、付けた絵文字の範囲を添える。
    /// 描く側は、名前と絵文字をカスタム絵文字の画像で、ほかの人の数を名前と同じ色で描き、ほかの部分を言い回しの色で描く。
    public struct NotificationHeader: Equatable, Sendable {
        public let text: String
        /// 操作した人の名前。種類の文が名前を含まない通知（投票の終了）ではnil。
        public let name: Range<String.Index>?
        /// まとめた通知の「ほかN人」。まとめていなければnil。
        public let otherAccounts: Range<String.Index>?
        /// 絵文字のリアクションで付けた絵文字。
        public let reactionEmoji: Range<String.Index>?
    }

    /// 通知の行の、誰が何をしたかの文。
    /// - Parameter otherAccountCount: まとめた通知で、最初の人を除いた数。まとめていなければnil。
    /// - Parameter reactionEmoji: 絵文字のリアクションの通知で、付けた絵文字を書いた文字（カスタム絵文字はショートコード）。nilなら種類の文で書く。
    public static func notificationHeader(
        _ appearance: NotificationAppearance,
        name: String,
        otherAccountCount: Int?,
        reactionEmoji: String?
    ) -> NotificationHeader {
        // 範囲は、組み立て終えた文の中の位置で返す。足す途中の位置は、あとの追加で変わりうるため、UTF-8での位置で覚えて最後に直す。
        var text = appearance.phrase.before
        var nameRange: Range<Int>?
        var othersRange: Range<Int>?
        var emojiRange: Range<Int>?
        func append(_ part: String) -> Range<Int> {
            let start = text.utf8.count
            text += part
            return start..<text.utf8.count
        }
        if appearance.phrase.includesName {
            nameRange = append(name)
            if let otherAccountCount {
                _ = append("と")
                othersRange = append(otherAccounts(count: otherAccountCount))
            }
        }
        if let reactionEmoji {
            _ = append("が")
            emojiRange = append(reactionEmoji)
            _ = append("でリアクションしました")
        } else {
            _ = append(appearance.phrase.after)
        }
        let final = text
        func range(_ offsets: Range<Int>?) -> Range<String.Index>? {
            offsets.map { final.utf8.index(final.startIndex, offsetBy: $0.lowerBound)..<final.utf8.index(final.startIndex, offsetBy: $0.upperBound) }
        }
        return NotificationHeader(text: final, name: range(nameRange), otherAccounts: range(othersRange), reactionEmoji: range(emojiRange))
    }

    /// 投票のボタンと、選択肢のない投票に出す文言。
    public enum Poll {
        public static let vote = "投票"
        public static let reveal = "結果を見る"
        public static let returnToVoting = "投票に戻る"
        public static let refresh = "更新"
        public static let empty = "選択肢がありません"
        /// 自分が票を入れた選択肢の読み上げ。
        public static let ownVote = "投票済み"
    }
}

extension ReplyLabel {
    /// 返信のラベルの文言。
    public var title: String {
        switch self {
        case .continuation: "続き"
        case .toMe: "自分への返信"
        case .toAccount(let acct): "@\(acct)への返信"
        case .unknownAccount: "返信"
        }
    }
}

extension QuoteDisplay.Reason {
    /// 引用元を出せない理由の文言。
    public var title: String {
        switch self {
        case .pending: "承認待ちの引用です"
        case .withdrawn: "引用元の投稿者が引用を取り消しました"
        case .deleted: "引用元の投稿は削除されました"
        case .unauthorized: "引用元の投稿を表示できません"
        case .blockedAccount: "ブロックしている人の投稿です"
        case .blockedDomain: "ブロックしているドメインの人の投稿です"
        case .mutedAccount: "ミュートしている人の投稿です"
        }
    }
}

extension MediaCover {
    /// ぼかしている理由。フィルターの名前を並べるところは、画面では`PostTexts.filterWarning`の区切りの範囲を境界線に置き換えて描く。使う人が隠した投稿に「閲覧注意」と出すと、投稿者が付けたように読めるため、文言を分ける。
    /// フィルターでぼかした投稿は、どのフィルターに一致したかを出す。
    public static func title(of cover: MediaCover?) -> String {
        switch cover {
        case .hidden: "非表示"
        case .filtered(let titles): PostTexts.filterWarning(titles: titles).text
        case .sensitive, nil: "閲覧注意"
        }
    }

    /// ぼかしている理由の読み上げ。
    public static func spokenTitle(of cover: MediaCover?) -> String {
        switch cover {
        case .filtered(let titles): PostTexts.filterWarningSpoken(titles: titles)
        case .hidden, .sensitive, nil: title(of: cover)
        }
    }
}
