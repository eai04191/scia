/// 設定の「投稿の見た目」と「通知の見た目」で使う人が調整する数値。値は`AppSettings`が持つ。
public struct AppearanceValue: Sendable, Identifiable, Hashable {
    public enum Unit: Sendable, Hashable {
        /// 長さ。値をそのままptで使う。
        case point
        /// 本文の文字の大きさ。iPhoneの文字サイズが標準のときの大きさとの差（pt）。
        case bodyTextOffset
        /// 本文以外の文字の大きさ。本文の文字の大きさとの差（pt）。
        case textOffset
        /// 単位のない割合。
        case ratio
        /// 行数。0なら出さない。
        case lines
    }

    /// 保存に使うキー。項目ごとに一意にする。
    public let id: String
    public let title: String
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double
    public let unit: Unit

    public init(id: String, title: String, range: ClosedRange<Double>, step: Double, defaultValue: Double, unit: Unit = .point) {
        precondition(range.contains(defaultValue), "\(id)の既定値が範囲外です")
        self.id = id
        self.title = title
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.unit = unit
    }
}

/// 投稿の部品ごとにまとめた項目。投稿の上から下への並びで並べる。
public struct AppearanceGroup: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let values: [AppearanceValue]

    public init(id: String, title: String, values: [AppearanceValue]) {
        self.id = id
        self.title = title
        self.values = values
    }
}

/// 投稿の見た目の項目の一覧。
///
/// 範囲は好みで狭めず、見た目として意味がある限り選べるようにする。長さと大きさは0から（0なら描かない）、上限は余白が100pt、大きさが200pt。
/// 文字は標準の文字サイズで1〜72ptほどになる範囲にする。0ptはUIKitでは書体の標準の大きさの意味になるため、文字だけは1ptを下限にする。
/// 縦長の比率は幅÷高さなので、0では高さが無限になる。0.1を下限にする。
/// 範囲の両端でも落ちたり並べ直しが止まらなくなったりしないことは、アプリのテスト（`AppearanceEditorTests`）で確かめる。
public enum AppearanceCatalog {
    // MARK: 文字

    /// 本文の文字の大きさ。ほかの文字は、ここからの差で決める。
    public static let bodyText = AppearanceValue(id: "text.body", title: "本文の文字", range: -14...57, step: 1, defaultValue: 0, unit: .bodyTextOffset)
    /// 名前の行で、太字で描く前の部分。名前の表記によって、名前かハンドルになる。
    public static let namePrimaryText = AppearanceValue(id: "text.namePrimary", title: "太字の部分の文字", range: -40...40, step: 1, defaultValue: 2, unit: .textOffset)
    /// 名前の行で、太字の後ろに添える部分。
    public static let nameSecondaryText = AppearanceValue(id: "text.nameSecondary", title: "添える部分の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    public static let timeText = AppearanceValue(id: "text.time", title: "時刻の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 名前の上の行の、ブーストした人の名前の文字。
    public static let contextText = AppearanceValue(id: "text.context", title: "ブーストした人の名前の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    public static let spoilerButtonText = AppearanceValue(id: "text.spoilerButton", title: "開くボタンの文字", range: -40...40, step: 1, defaultValue: -2, unit: .textOffset)
    public static let linkCardTitleText = AppearanceValue(id: "text.linkCardTitle", title: "タイトルの文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// リンクカードのサイト名と説明の文字。
    public static let linkCardDetailText = AppearanceValue(id: "text.linkCardDetail", title: "サイト名と説明の文字", range: -40...40, step: 1, defaultValue: -3, unit: .textOffset)
    /// 投票の票数や締め切りと、その横のボタンの文字。
    public static let pollFooterText = AppearanceValue(id: "text.pollFooter", title: "票数と締め切りの文字", range: -40...40, step: 1, defaultValue: -2, unit: .textOffset)

    /// 自分の投稿が自分のフィルターに一致したことを示す、本文の下の注記の文字。
    public static let filterNoteText = AppearanceValue(id: "text.filterNote", title: "注記の文字", range: -40...40, step: 1, defaultValue: -2, unit: .textOffset)
    /// 引用とXの投稿の囲みの、作者の行の文字。名前は太字で、ハンドルは控えめに描く。
    public static let xPostNameText = AppearanceValue(id: "text.xPostName", title: "作者の行の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 引用とXの投稿の囲みの、本文の文字。
    public static let xPostBodyText = AppearanceValue(id: "text.xPostBody", title: "本文の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 名前の上の行の、返信先と固定された投稿を示すラベルの文字。
    public static let contextLabelText = AppearanceValue(id: "text.contextLabel", title: "返信と固定のラベルの文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 名前の上の行で、ブーストした人の名前の後ろに添える部分の文字。
    public static let contextSecondaryText = AppearanceValue(id: "text.contextSecondary", title: "ブーストした人の添える部分の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)

    // MARK: 大きさと余白

    // 行の余白の既定値は、一覧のセルの標準の余白（`defaultContentConfiguration()`、iPhone）に合わせる。
    public static let rowPaddingTop = AppearanceValue(id: "timeline.rowPaddingTop", title: "上の余白", range: 0...100, step: 1, defaultValue: 15)
    public static let rowPaddingBottom = AppearanceValue(id: "timeline.rowPaddingBottom", title: "下の余白", range: 0...100, step: 1, defaultValue: 15)
    public static let rowPaddingLeading = AppearanceValue(id: "timeline.rowPaddingLeading", title: "左の余白", range: 0...100, step: 1, defaultValue: 16)
    public static let rowPaddingTrailing = AppearanceValue(id: "timeline.rowPaddingTrailing", title: "右の余白", range: 0...100, step: 1, defaultValue: 8)
    /// 名前の行で、太字の部分と、後ろに添える部分のすき間。
    public static let namePartsSpacing = AppearanceValue(id: "timeline.namePartsSpacing", title: "太字と添える部分のすき間", range: 0...100, step: 1, defaultValue: 4)
    /// 名前と時刻のあいだの、最も狭いすき間。時刻は右端に寄せるので、名前が短ければもっと空く。
    public static let nameTimeSpacing = AppearanceValue(id: "timeline.nameTimeSpacing", title: "名前と時刻の最小のすき間", range: 0...100, step: 1, defaultValue: 8)
    /// 本文の行と行のあいだに足す余白。
    public static let bodyLineSpacing = AppearanceValue(id: "timeline.bodyLineSpacing", title: "行間", range: 0...100, step: 1, defaultValue: 0)
    /// 注意書きのボックスの、注意書きの文字と開くボタンのあいだ。
    public static let spoilerButtonSpacing = AppearanceValue(id: "timeline.spoilerButtonSpacing", title: "文字と開くボタンのあいだ", range: 0...100, step: 1, defaultValue: 4)
    /// 添付ファイルが1つの投稿で、縦長の画像をどこまで縦長のまま出すか（幅÷高さ）。これより縦長なものは上下を切り落とす。
    public static let mediaTallestAspectRatio = AppearanceValue(id: "timeline.mediaTallestAspectRatio", title: "1枚の画像の最も縦長な比率（幅÷高さ）", range: 0.1...4, step: 0.05, defaultValue: 0.75, unit: .ratio)
    /// リンクカードの説明の行数。0なら説明を出さない。
    public static let linkCardDescriptionLines = AppearanceValue(id: "timeline.linkCardDescriptionLines", title: "説明の行数", range: 0...10, step: 1, defaultValue: 1, unit: .lines)
    /// リンクカードの、サイト名・タイトル・説明の行どうしのあいだ。
    public static let linkCardLineSpacing = AppearanceValue(id: "timeline.linkCardLineSpacing", title: "行のあいだ", range: 0...100, step: 1, defaultValue: 2)
    /// 名前やブーストした人の行が入りきらないときに、行末をぼかす幅。
    public static let nameFadeWidth = AppearanceValue(id: "timeline.nameFadeWidth", title: "入りきらない名前の行末をぼかす幅", range: 0...100, step: 1, defaultValue: 20)
    /// 時刻の前の公開範囲の記号と、時刻のすき間。
    public static let visibilitySymbolSpacing = AppearanceValue(id: "timeline.visibilitySymbolSpacing", title: "公開範囲の記号と時刻のすき間", range: 0...100, step: 1, defaultValue: 4)
    /// 時刻の前の編集済みの「*」と、時刻のすき間。
    public static let editedMarkSpacing = AppearanceValue(id: "timeline.editedMarkSpacing", title: "「*」と時刻のすき間", range: 0...100, step: 1, defaultValue: 0)
    /// 本文の引用とリストの、1段あたりの字下げ。
    public static let quoteIndent = AppearanceValue(id: "timeline.quoteIndent", title: "引用とリストの字下げ", range: 0...100, step: 1, defaultValue: 16)
    /// 本文と注意書きのカスタム絵文字の高さの、絵文字の標準の大きさ（絵文字を文字の大きさのまま描いたときの絵の高さ）に対する割合。
    /// 絵文字の大きさと同じ割合なら、同じ高さに描く。
    public static let customEmojiScale = AppearanceValue(id: "timeline.customEmojiScale", title: "カスタム絵文字の大きさ", range: 0...4, step: 0.1, defaultValue: 1, unit: .ratio)
    /// 名前の行と名前の上の行のカスタム絵文字の高さの、絵文字の標準の大きさに対する割合。
    public static let nameCustomEmojiScale = AppearanceValue(id: "timeline.nameCustomEmojiScale", title: "カスタム絵文字の大きさ", range: 0...4, step: 0.1, defaultValue: 1, unit: .ratio)
    /// 本文と注意書きの、カスタム絵文字でない絵文字の絵の高さの、標準の大きさ（文字の大きさのまま描いたときの絵の高さ）に対する割合。
    /// 0にすると書体の大きさが0ptになり、書体の標準の大きさで描かれるため、下限を0より上にする。
    public static let unicodeEmojiScale = AppearanceValue(id: "timeline.unicodeEmojiScale", title: "絵文字の大きさ", range: 0.5...4, step: 0.1, defaultValue: 1, unit: .ratio)
    /// 名前の行と名前の上の行の、カスタム絵文字でない絵文字の絵の高さの、標準の大きさに対する割合。
    public static let nameUnicodeEmojiScale = AppearanceValue(id: "timeline.nameUnicodeEmojiScale", title: "絵文字の大きさ", range: 0.5...4, step: 0.1, defaultValue: 1, unit: .ratio)
    /// アイコンを角丸の四角にしたときの、角の丸みの一辺に対する割合。0.5で円になる。
    public static let avatarCornerRatio = AppearanceValue(id: "timeline.avatarCornerRatio", title: "角丸の四角の丸み（一辺に対する割合）", range: 0...0.5, step: 0.05, defaultValue: 0.2, unit: .ratio)
    /// 注意書きのボックスの角の丸み。
    public static let spoilerCornerRadius = AppearanceValue(id: "timeline.spoilerCornerRadius", title: "ボックスの角の丸み", range: 0...100, step: 1, defaultValue: 8)
    /// 本文などと、自分のフィルターに一致したことを示す注記のあいだ。
    public static let filterNoteSpacing = AppearanceValue(id: "timeline.filterNoteSpacing", title: "注記とのあいだ", range: 0...100, step: 1, defaultValue: 10)
    /// 添付ファイルが1つの投稿で、横長の画像をどこまで横長のまま出すか（幅÷高さ）。これより横長なものは左右を切り落とす。
    public static let mediaWidestAspectRatio = AppearanceValue(id: "timeline.mediaWidestAspectRatio", title: "1枚の画像の最も横長な比率（幅÷高さ）", range: 1...10, step: 0.1, defaultValue: 3, unit: .ratio)
    /// 添付ファイルを本文の右に並べるときの、正方形の一辺。2つ以上を重ねるときも、重なり全体をこの正方形に収める。
    public static let mediaBesideSide = AppearanceValue(id: "timeline.mediaBesideSide", title: "右に並べるときの大きさ", range: 0...200, step: 1, defaultValue: 64)
    /// リンクカードのタイトルの行数。
    public static let linkCardTitleLines = AppearanceValue(id: "timeline.linkCardTitleLines", title: "タイトルの行数", range: 1...10, step: 1, defaultValue: 1, unit: .lines)
    /// リンクカードの画像の幅の上限の、カードの幅に対する割合。画像はカードの高さの正方形にし、これより広くしない。
    public static let linkCardImageWidthRatio = AppearanceValue(id: "timeline.linkCardImageWidthRatio", title: "画像の幅の上限（カードの幅に対する割合）", range: 0...1, step: 0.05, defaultValue: 0.3, unit: .ratio)
    /// 投票の選択肢の、枠と記号や割合のあいだの左右の余白。
    public static let pollOptionHorizontalPadding = AppearanceValue(id: "timeline.pollOptionHorizontalPadding", title: "選択肢の左右の余白", range: 0...100, step: 1, defaultValue: 10)
    /// 投票の選択肢の枠の角の丸み。
    public static let pollOptionCornerRadius = AppearanceValue(id: "timeline.pollOptionCornerRadius", title: "選択肢の角の丸み", range: 0...100, step: 1, defaultValue: 8)
    /// 投票の最後の選択肢と、票数と締め切りの行のあいだ。
    public static let pollFooterSpacing = AppearanceValue(id: "timeline.pollFooterSpacing", title: "選択肢と票数のあいだ", range: 0...100, step: 1, defaultValue: 6)

    /// 投稿本文の段落と段落のあいだの余白。
    public static let paragraphSpacing = AppearanceValue(id: "timeline.paragraphSpacing", title: "段落のあいだ", range: 0...100, step: 1, defaultValue: 6)
    /// 投稿の左に出すアイコンの一辺。
    public static let avatarSize = AppearanceValue(id: "timeline.avatarSize", title: "大きさ", range: 0...200, step: 1, defaultValue: 40)
    /// ブーストした人の行に出すアイコンの一辺。
    public static let boosterAvatarSize = AppearanceValue(id: "timeline.boosterAvatarSize", title: "ブーストした人のアイコン", range: 0...200, step: 1, defaultValue: 16)
    /// 返信と返信先の行のアイコン同士をつなぐ線の太さ。
    public static let replyLineWidth = AppearanceValue(id: "timeline.replyLineWidth", title: "返信をつなぐ線の太さ", range: 0...20, step: 0.5, defaultValue: 2)
    /// 返信をつなぐ線と、アイコンのあいだのすき間。
    public static let replyLineGap = AppearanceValue(id: "timeline.replyLineGap", title: "返信をつなぐ線とのすき間", range: 0...100, step: 1, defaultValue: 4)
    /// 投稿と通知の行で、左のアイコンの列と、右の文字の列のあいだ。
    public static let avatarSpacing = AppearanceValue(id: "timeline.avatarSpacing", title: "文字の列とのあいだ", range: 0...100, step: 1, defaultValue: 10)
    /// 名前の上の行の記号と、文字の列のあいだ。ブーストした人のアイコンがあれば、そのアイコンとのあいだになる。
    /// 記号はアイコンの列の右端に揃えず、文字の列からこの幅だけ離して置く。記号どうしの縦の揃いは保たれる。
    public static let contextSymbolSpacing = AppearanceValue(id: "timeline.contextSymbolSpacing", title: "記号とのすき間", range: 0...100, step: 1, defaultValue: 4)
    /// 名前の上の行で、ブーストした人の名前の部分と、後ろに添える部分のすき間。
    public static let contextPartsSpacing = AppearanceValue(id: "timeline.contextPartsSpacing", title: "ブーストした人の名前と添える部分のすき間", range: 0...100, step: 1, defaultValue: 4)
    /// 名前の上の行の、ブーストした人のアイコンと文字のすき間。
    public static let contextAvatarTextSpacing = AppearanceValue(id: "timeline.contextAvatarTextSpacing", title: "アイコンと文字のすき間", range: 0...100, step: 1, defaultValue: 4)
    /// ブーストや固定、通知の種類を示す名前の上の行と、名前の行のあいだ。
    public static let contextSpacing = AppearanceValue(id: "timeline.contextSpacing", title: "名前の行とのあいだ", range: 0...100, step: 1, defaultValue: 4)
    /// 投稿の名前の行と本文のあいだ。
    public static let nameBodySpacing = AppearanceValue(id: "timeline.nameBodySpacing", title: "本文とのあいだ", range: 0...100, step: 1, defaultValue: 5)
    /// 本文のない投稿で、名前の行と、添付ファイルのサムネイルのあいだ。
    public static let nameMediaSpacing = AppearanceValue(id: "timeline.nameMediaSpacing", title: "本文がないときのメディアとのあいだ", range: 0...100, step: 1, defaultValue: 12)
    /// 注意書き（CW）のボックスの内側の余白。
    public static let spoilerPadding = AppearanceValue(id: "timeline.spoilerPadding", title: "ボックスの内側の余白", range: 0...100, step: 1, defaultValue: 9)
    /// 注意書き（CW）のボックスと、開いた本文のあいだ。
    public static let spoilerBodySpacing = AppearanceValue(id: "timeline.spoilerBodySpacing", title: "本文とのあいだ", range: 0...100, step: 1, defaultValue: 9)
    /// 投稿の本文と、添付ファイルのサムネイルのあいだ。
    public static let bodyMediaSpacing = AppearanceValue(id: "timeline.bodyMediaSpacing", title: "本文とのあいだ", range: 0...100, step: 1, defaultValue: 10)
    /// 添付ファイルのサムネイルを並べるときの、サムネイル同士のすき間。
    public static let mediaTileSpacing = AppearanceValue(id: "timeline.mediaTileSpacing", title: "サムネイル同士のすき間", range: 0...100, step: 1, defaultValue: 4)
    /// 投稿の本文や添付ファイルと、リンクカードのあいだ。
    public static let bodyLinkCardSpacing = AppearanceValue(id: "timeline.bodyLinkCardSpacing", title: "本文とのあいだ", range: 0...100, step: 1, defaultValue: 10)
    /// リンクカードの文字の、枠とサムネイルからの余白。
    public static let linkCardPadding = AppearanceValue(id: "timeline.linkCardPadding", title: "内側の余白", range: 0...100, step: 1, defaultValue: 10)
    /// 投稿の本文や添付ファイルと、引用とXの投稿の囲みのあいだ。
    public static let bodyXPostSpacing = AppearanceValue(id: "timeline.bodyXPostSpacing", title: "投稿の本文とのあいだ", range: 0...100, step: 1, defaultValue: 10)
    /// 引用とXの投稿の囲みの内側の余白。
    public static let xPostPadding = AppearanceValue(id: "timeline.xPostPadding", title: "内側の余白", range: 0...100, step: 1, defaultValue: 10)
    /// 引用とXの投稿の囲みの、作者のアイコンと名前のすき間。
    public static let xPostAvatarNameSpacing = AppearanceValue(id: "timeline.xPostAvatarNameSpacing", title: "アイコンと名前のすき間", range: 0...100, step: 1, defaultValue: 10)
    /// 引用とXの投稿の囲みの、作者の行と本文のあいだ。
    public static let xPostHeaderSpacing = AppearanceValue(id: "timeline.xPostHeaderSpacing", title: "作者の行と本文のあいだ", range: 0...100, step: 1, defaultValue: 10)
    /// 引用とXの投稿の囲みの、本文とメディアのあいだ。
    public static let xPostMediaSpacing = AppearanceValue(id: "timeline.xPostMediaSpacing", title: "本文とメディアのあいだ", range: 0...100, step: 1, defaultValue: 10)
    /// 引用とXの投稿の囲みの、作者の行に出すアイコンの一辺。
    public static let xPostAvatarSize = AppearanceValue(id: "timeline.xPostAvatarSize", title: "アイコンの大きさ", range: 0...200, step: 1, defaultValue: 20)
    /// 本文と投票のあいだ。
    public static let bodyPollSpacing = AppearanceValue(id: "timeline.bodyPollSpacing", title: "本文とのあいだ", range: 0...100, step: 1, defaultValue: 10)
    /// 投票の選択肢どうしのあいだ。
    public static let pollOptionSpacing = AppearanceValue(id: "timeline.pollOptionSpacing", title: "選択肢のあいだ", range: 0...100, step: 1, defaultValue: 6)
    /// 投票の選択肢の、文字の上下の余白。
    public static let pollOptionPadding = AppearanceValue(id: "timeline.pollOptionPadding", title: "選択肢の上下の余白", range: 0...100, step: 1, defaultValue: 8)

    // MARK: お気に入りとブーストの光

    /// 下の端から照らす光の高さ。光は行の中にだけ伸ばす。ライトでHDRを使わずに描くときは、`ReactionGlow.Style`でこの高さを縮める。
    public static let reactionGlowHeight = AppearanceValue(id: "reactionGlow.height", title: "光の高さ", range: 0...200, step: 2, defaultValue: 64)
    public static let reactionGlowDarkOpacity = AppearanceValue(id: "reactionGlow.darkOpacity", title: "光の濃さ（ダークモード）", range: 0...1, step: 0.05, defaultValue: 0.4, unit: .ratio)
    /// ライトでHDRで描くときの濃さ。HDRを使わずに描くときは、`ReactionGlow.Style`でこの濃さを薄める。
    public static let reactionGlowLightOpacity = AppearanceValue(id: "reactionGlow.lightOpacity", title: "光の濃さ（ライトモード）", range: 0...1, step: 0.05, defaultValue: 0.95, unit: .ratio)
    /// 左半分のブーストと右半分のお気に入りの光を、真ん中で混ぜる幅。0でくっきり分ける。
    public static let reactionGlowBlendWidth = AppearanceValue(id: "reactionGlow.blendWidth", title: "真ん中で2色を混ぜる幅", range: 0...400, step: 4, defaultValue: 48)
    /// 光に添えるアイコンの大きさ。散らすときは、これを基準に大きさを変える。
    /// 0ptの記号は書体の標準の大きさで描かれ、小さくしたつもりが大きくなるため、文字と同じく1ptを下限にする。
    public static let reactionGlowIconSize = AppearanceValue(id: "reactionGlow.iconSize", title: "アイコンの大きさ", range: 1...200, step: 1, defaultValue: 8)
    /// 光に添えるアイコンの濃さ。光より目立たせないため、既定では薄くする。
    public static let reactionGlowIconOpacity = AppearanceValue(id: "reactionGlow.iconOpacity", title: "アイコンの濃さ", range: 0...1, step: 0.05, defaultValue: 0.6, unit: .ratio)

    public static let groups: [AppearanceGroup] = [
        AppearanceGroup(id: "row", title: "行", values: [rowPaddingTop, rowPaddingBottom, rowPaddingLeading, rowPaddingTrailing]),
        AppearanceGroup(id: "context", title: "名前の上の行", values: [contextText, contextSecondaryText, contextPartsSpacing, contextLabelText, boosterAvatarSize, contextSymbolSpacing, contextAvatarTextSpacing, contextSpacing]),
        AppearanceGroup(id: "avatar", title: "アイコン", values: [avatarSize, avatarCornerRatio, avatarSpacing, replyLineWidth, replyLineGap]),
        AppearanceGroup(id: "name", title: "名前の行", values: [namePrimaryText, nameSecondaryText, timeText, namePartsSpacing, nameTimeSpacing, visibilitySymbolSpacing, editedMarkSpacing, nameFadeWidth, nameUnicodeEmojiScale, nameCustomEmojiScale, nameBodySpacing, nameMediaSpacing]),
        AppearanceGroup(id: "body", title: "本文", values: [bodyText, bodyLineSpacing, paragraphSpacing, quoteIndent, unicodeEmojiScale, customEmojiScale, filterNoteText, filterNoteSpacing]),
        AppearanceGroup(id: "spoiler", title: "注意書き", values: [spoilerButtonText, spoilerButtonSpacing, spoilerPadding, spoilerCornerRadius, spoilerBodySpacing]),
        AppearanceGroup(id: "media", title: "メディア", values: [bodyMediaSpacing, mediaTileSpacing, mediaTallestAspectRatio, mediaWidestAspectRatio, mediaBesideSide]),
        AppearanceGroup(id: "linkCard", title: "リンクカード", values: [linkCardTitleText, linkCardDetailText, linkCardTitleLines, linkCardDescriptionLines, linkCardLineSpacing, linkCardImageWidthRatio, bodyLinkCardSpacing, linkCardPadding]),
        // Xの投稿の囲みも同じ値を使うが、Xの投稿は既定では出さない試作のため、名前には書かない。
        AppearanceGroup(id: Self.xPostGroupID, title: "引用", values: [xPostNameText, xPostBodyText, xPostAvatarSize, xPostAvatarNameSpacing, xPostHeaderSpacing, xPostMediaSpacing, xPostPadding, bodyXPostSpacing]),
        AppearanceGroup(id: "poll", title: "投票", values: [pollFooterText, bodyPollSpacing, pollOptionSpacing, pollOptionPadding, pollOptionHorizontalPadding, pollOptionCornerRadius, pollFooterSpacing]),
        AppearanceGroup(id: "reactionGlow", title: "お気に入りとブーストの光", values: [reactionGlowHeight, reactionGlowDarkOpacity, reactionGlowLightOpacity, reactionGlowBlendWidth, reactionGlowIconSize, reactionGlowIconOpacity]),
    ]

    public static let values: [AppearanceValue] = groups.flatMap(\.values)

    /// Xの投稿の部品の区画。Xの投稿を出すのは試作で、出すようにしているときだけ並べる。
    public static let xPostGroupID = "xPost"
}
