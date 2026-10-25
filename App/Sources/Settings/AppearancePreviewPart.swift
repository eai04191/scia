import UIKit

/// 「投稿の見た目」のプレビューで、調整している項目の場所を示すための、投稿の部品。
enum AppearancePreviewPart: Hashable, CaseIterable {
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
    /// リンクカードのサイト名。
    case cardSite
    case media
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
}

extension AppearancePreviewPart {
    /// 部品ではなく、すき間や余白、角のような場所か。場所は塗って示し、部品は中を隠さないよう外側に枠を引いて示す。
    var isArea: Bool {
        switch self {
        case .rowPaddingTop, .rowPaddingBottom, .rowPaddingLeading, .rowPaddingTrailing,
             .mediaTileGaps, .pollOptionGaps, .pollOptionPadding, .pollOptionSidePadding, .pollOptionCorners,
             .cardLineGaps, .cardPaddingBands, .xPostPaddingBands, .spoilerPaddingBands, .spoilerCorners,
             .bodyLineGaps, .bodyParagraphGaps, .quoteIndent, .visibilitySymbolGap, .editedMarkGap,
             .nameFade, .nameTimeMinGap, .avatarCorners:
            true
        default:
            false
        }
    }
}

/// 部品ごとの枠。1つの部品が離れた複数の枠を持つことがある（リンクカードのサイト名と説明など）。
typealias AppearancePreviewFrames = [AppearancePreviewPart: [CGRect]]

extension UIView {
    /// 表示中なら、このビューの枠を`space`の座標で返す。大きさを0にした部品も、場所を示せるよう、幅や高さが0の枠を返す。
    func previewFrame(in space: UIView) -> [CGRect]? {
        guard !isHidden, window != nil || superview != nil else { return nil }
        return [convert(bounds, to: space)]
    }
}
