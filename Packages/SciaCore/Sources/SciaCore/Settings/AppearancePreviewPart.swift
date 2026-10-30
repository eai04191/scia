public import CoreGraphics

/// 「投稿の見た目」と「通知の見た目」のプレビューで、調整している項目の場所を示すための、投稿と通知の行の部品。
public enum AppearancePreviewPart: Hashable, CaseIterable, Sendable {
    case rowPaddingTop
    case rowPaddingBottom
    case rowPaddingLeading
    case rowPaddingTrailing
    case contextSymbol
    case contextAvatar
    /// 名前の上の行の文字の全体。
    case contextLine
    /// 名前の上の行の文字の、名前の部分。添える部分がなければ全体。
    case contextText
    /// 名前の上の行の文字の、名前の後ろに添える部分。
    case contextSecondary
    case avatar
    /// アイコンの四隅。
    case avatarCorners
    /// アイコンから下の行へ伸ばす、返信をつなぐ線。
    case replyLineBelow
    case nameRow
    /// 名前の字面。ベースラインからem枠で測った上端と下端。
    case nameGlyphs
    case namePrimary
    case nameSecondary
    case time
    /// 公開範囲の記号。消していれば、記号があった位置。
    case visibilitySymbol
    case visibilitySymbolGap
    /// 編集済みの「*」。消していれば、「*」があった位置。
    case editedMark
    case editedMarkGap
    /// 名前の行と名前の上の行のカスタム絵文字。
    case nameCustomEmojis
    /// 名前の行と名前の上の行の、大きさを変えた絵文字。等倍のときは示さない。
    case nameUnicodeEmojis
    /// 入りきらない名前の行末をぼかしている部分。
    case nameFade
    /// 名前が入りきらず時刻に詰まった投稿の、名前と時刻のすき間。最小のすき間がそのまま空く。
    case nameTimeMinGap
    /// 消せる部品の場所。出ていればその部品を、消していれば部品があった位置を示す。
    case contextSymbolSlot
    case boosterAvatarSlot
    case replyLabelSlot
    case timeSlot
    case replyLineSlot
    case cardSlot
    case cardImageSlot
    case cardSiteSlot
    /// サムネイルのALTやGIFのバッジ。
    case mediaBadgeSlot
    /// 投稿の下の区切り線の位置。
    case separatorLine
    /// 公開範囲の記号を付けた投稿の時刻。
    case visibilityTime
    /// 編集済みの「*」を付けた投稿の時刻。
    case editedTime
    /// ブーストした人の行の文字。
    case boostLine
    /// 返信のラベル。ラベルを出さない設定では、ラベルが出る名前の行。
    case replyLabel
    /// 下の行と線でつながっている投稿のアイコン。
    case connectedAvatar
    /// リンクカードの画像。
    case cardImage
    case spoiler
    case spoilerText
    /// 注意書きのボックスの内側の余白。
    case spoilerPaddingBands
    /// 注意書きのボックスの四隅。
    case spoilerCorners
    case spoilerButton
    case bodyText
    /// 本文の字面。最初と最後のベースラインからem枠で測った上端と下端。
    case bodyGlyphs
    /// 本文の、段落の中の行と行のあいだ。
    case bodyLineGaps
    /// 本文の、段落と段落のあいだ。
    case bodyParagraphGaps
    /// 本文の、引用やリストの字下げの部分。
    case quoteIndent
    /// 本文のカスタム絵文字。
    case customEmojis
    /// 本文の、大きさを変えた絵文字。等倍のときは示さない。
    case unicodeEmojis
    /// 絵文字だけの本文の、カスタム絵文字と大きさを変えた絵文字。
    case emojiOnlyEmojis
    /// 絵文字だけの本文。大きくしていないときも示す。
    case emojiOnlyBody
    /// リンクカードのサイト名。
    case cardSite
    case media
    /// 本文の右に小さく出した添付ファイル。本文の下に並べたときの`media`とは示す項目が違うため分ける。
    case besideMedia
    /// 添付ファイルが1つのときのサムネイル。
    case singleMedia
    /// 縦長の添付ファイル1つのサムネイル。
    case singleTallMedia
    /// 横長の添付ファイル1つのサムネイル。
    case singleWideMedia
    /// 隣り合うサムネイルのあいだ。
    case mediaTileGaps
    case card
    case cardTitle
    case cardDescription
    /// サイト名、タイトル、説明の行のあいだ。
    case cardLineGaps
    /// リンクカードの文字の側の、内側の余白。
    case cardPaddingBands
    /// リンクカードのサイト名と説明。
    case cardDetail
    /// Xの投稿の囲み。
    case xPost
    case xPostAvatar
    case xPostName
    /// Xの投稿の囲みの、作者のアイコンと名前を並べた行。
    case xPostHeader
    case xPostBody
    case xPostMedia
    /// Xの投稿の囲みの内側の余白。
    case xPostPaddingBands
    case poll
    /// 選択肢を並べた部分。
    case pollOptions
    /// 選択肢の枠の四隅。
    case pollOptionCorners
    /// 票数と締め切りの文字。
    case pollSummary
    /// 隣り合う選択肢のあいだ。
    case pollOptionGaps
    /// 選択肢の枠の左右の余白の帯。
    case pollOptionSidePadding
    /// 選択肢の枠と文字のあいだの、上と下の帯。
    case pollOptionPadding
    case pollFooter
    /// 自分のフィルターに一致したことを示す注記。
    case filterNote
    /// お気に入りとブーストの光の全体。
    case reactionGlow
    /// お気に入りとブーストの片方だけをした投稿の光。
    case reactionGlowAlone
    /// 光の真ん中で、ブーストとお気に入りの2色を混ぜる幅。
    case reactionGlowBlend
    /// 光に添えたアイコン。
    case reactionGlowIcons

    // MARK: 通知の行

    /// 通知の種類を示す記号。メンションなどの投稿として出す通知では、名前の上の行の記号（`contextSymbol`）になる。
    case notificationSymbol
    /// 誰が何をしたかの行。
    case notificationHeader
    /// 誰が何をしたかの行の字面。下端は、最後のベースラインからem枠で測る。
    case notificationHeaderGlyphs
    /// 名前の前に差し込んだアイコン。
    case notificationHeaderAvatar
    /// 名前の前のアイコンと名前のすき間。
    case notificationHeaderAvatarGap
    /// まとめた通知で並べたアイコン。行の幅で切れた分は含めない。
    case groupAvatars
    /// まとめた通知で、隣り合うアイコンのあいだ。
    case groupAvatarGaps
    /// フォローなどの通知で、誰が何をしたかの行の下に添えたハンドル。
    case notificationAccount
    /// 添えたハンドルの字面。
    case notificationAccountGlyphs
    /// 再掲する投稿の注意書きのボックス。
    case quotedSpoiler
    /// 再掲する投稿の本文。
    case quotedBodyText
    /// 再掲する投稿の本文の字面。
    case quotedBodyGlyphs
    /// 再掲する投稿のサムネイルを1列に並べた部分。
    case quotedMedia
    /// 1列に並べたサムネイル。行の幅で切れた分も含める。
    case quotedThumbnails
    /// 1列に並べたサムネイル同士のあいだ。
    case quotedThumbnailGaps
    /// 結果の形で足した投票。
    case quotedPoll
    /// 引用のある投稿であることを示す1行。
    case quotedNote
}

extension AppearancePreviewPart {
    /// 部品ではなく、すき間や余白、角のような場所か。場所は塗って示し、部品は中を隠さないよう外側に枠を引いて示す。
    public var isArea: Bool {
        switch self {
        case .rowPaddingTop, .rowPaddingBottom, .rowPaddingLeading, .rowPaddingTrailing,
             .mediaTileGaps, .pollOptionGaps, .pollOptionPadding, .pollOptionSidePadding, .pollOptionCorners,
             .cardLineGaps, .cardPaddingBands, .xPostPaddingBands, .spoilerPaddingBands, .spoilerCorners,
             .bodyLineGaps, .bodyParagraphGaps, .quoteIndent, .visibilitySymbolGap, .editedMarkGap,
             .nameFade, .nameTimeMinGap, .avatarCorners,
             .notificationHeaderAvatarGap, .groupAvatarGaps, .quotedThumbnailGaps:
            true
        default:
            false
        }
    }
}

extension AppearancePreviewPart {
    /// 通知の行だけにある部品。「投稿の見た目」の項目は開かない。
    public static let notificationParts: Set<AppearancePreviewPart> = [
        .notificationSymbol, .notificationHeader, .notificationHeaderGlyphs, .notificationHeaderAvatar, .notificationHeaderAvatarGap,
        .groupAvatars, .groupAvatarGaps, .notificationAccount, .notificationAccountGlyphs,
        .quotedSpoiler, .quotedBodyText, .quotedBodyGlyphs, .quotedMedia, .quotedThumbnails, .quotedThumbnailGaps, .quotedPoll, .quotedNote,
    ]
}

/// 部品ごとの枠。1つの部品が離れた複数の枠を持つことがある（リンクカードのサイト名と説明など）。
public typealias AppearancePreviewFrames = [AppearancePreviewPart: [CGRect]]
