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
        /// 割合。範囲の上限を100%として%で表示し、保存する値は割合のまま持つ。
        case percent
        /// 行数。0なら出さない。
        case lines
        /// 個数。
        case count
    }

    /// 保存に使うキー。項目ごとに一意にする。
    public let id: String
    public let title: String
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double
    public let unit: Unit
    /// 長さの項目の役割。長さ（`.point`）の項目は必ず持つ（テストで確かめる）。
    public let role: Role?
    /// プリセットに持つ値のキー。行を描くたびに読むので、読むたびに組み立てない。
    let presetKey: String

    /// 長さの項目の役割。
    public enum Role: Sendable, Hashable {
        /// gapの段。既定値は段の長さで、組み込みのプリセットは段の単位を変えて決める。
        case spacing(SpacingScale.Level)
        /// 段によらない長さ（大きさ、線の太さ、radiusなど）。
        case free
    }

    public init(id: String, title: String, range: ClosedRange<Double>, step: Double, defaultValue: Double, unit: Unit = .point, role: Role? = nil) {
        precondition(range.contains(defaultValue), "\(id)の既定値が範囲外です")
        self.id = id
        presetKey = "appearanceValue.\(id)"
        self.title = title
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.unit = unit
        self.role = role
    }

    /// 値の欄に出す数。%の項目は、範囲の上限を100にした数にする。0.4×100が40.00000000000001になるような端数は、表示の桁を増やさないよう丸める。
    public func displayNumber(for value: Double) -> Double {
        unit == .percent ? (value / range.upperBound * 100 * 1e6).rounded() / 1e6 : value
    }

    /// 値の欄に打った数を、保存する値に直す。
    public func storedValue(fromDisplayNumber number: Double) -> Double {
        unit == .percent ? (number / 100 * range.upperBound * 1e9).rounded() / 1e9 : number
    }

    /// gapの段の項目。既定値は段の長さにする。
    public init(id: String, title: String, range: ClosedRange<Double>, step: Double, spacing level: SpacingScale.Level) {
        self.init(id: id, title: title, range: range, step: step, defaultValue: level.value(), role: .spacing(level))
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

/// 投稿の見た目の項目のリスト。
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
    public static let namePrimaryText = AppearanceValue(id: "text.namePrimary", title: "太字の部分の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
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
    /// 絵文字のリアクションのボタンの、絵文字と数の文字。
    public static let reactionText = AppearanceValue(id: "text.reaction", title: "絵文字と数の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)

    /// 自分の投稿が自分のフィルターに一致したことを示す、本文の下の注記の文字。
    public static let filterNoteText = AppearanceValue(id: "text.filterNote", title: "注記の文字", range: -40...40, step: 1, defaultValue: -2, unit: .textOffset)
    /// 引用とXの投稿のカードの、作者の行の文字。名前は太字で、ハンドルは控えめに描く。
    public static let xPostNameText = AppearanceValue(id: "text.xPostName", title: "作者の行の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 引用とXの投稿のカードの、本文の文字。
    public static let xPostBodyText = AppearanceValue(id: "text.xPostBody", title: "本文の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 名前の上の行の、返信先と固定された投稿を示すラベルの文字。
    public static let contextLabelText = AppearanceValue(id: "text.contextLabel", title: "返信と固定のラベルの文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 名前の上の行で、ブーストした人の名前の後ろに添える部分の文字。
    public static let contextSecondaryText = AppearanceValue(id: "text.contextSecondary", title: "ブーストした人の添える部分の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)

    // MARK: 大きさと余白

    // 行の上下の余白は行の外周のgapの段にする。左右は画面の端からの余白で、投稿の中のgapとは役割が違うので、段によらず、組み込みのプリセットでも変えない。
    public static let rowPaddingTop = AppearanceValue(id: "timeline.rowPaddingTop", title: "上の余白", range: 0...100, step: 1, spacing: .s4)
    public static let rowPaddingBottom = AppearanceValue(id: "timeline.rowPaddingBottom", title: "下の余白", range: 0...100, step: 1, spacing: .s4)
    public static let rowPaddingLeading = AppearanceValue(id: "timeline.rowPaddingLeading", title: "左の余白", range: 0...100, step: 1, defaultValue: 16, role: .free)
    public static let rowPaddingTrailing = AppearanceValue(id: "timeline.rowPaddingTrailing", title: "右の余白", range: 0...100, step: 1, defaultValue: 16, role: .free)
    /// 名前の行で、太字の部分と、後ろに添える部分のgap。
    public static let namePartsSpacing = AppearanceValue(id: "timeline.namePartsSpacing", title: "太字と添える部分の間隔", range: 0...100, step: 1, spacing: .s1)
    /// 名前とハンドルを2段に分けるとき、1段目の字面の下端から2段目の字面の上端まで。
    public static let nameStackSpacing = AppearanceValue(id: "timeline.nameStackSpacing", title: "1段目と2段目のあいだ", range: 0...100, step: 1, spacing: .s1)
    /// 名前と時刻のあいだの、最も狭いgap。時刻は右端に寄せるので、名前が短ければもっと空く。
    public static let nameTimeSpacing = AppearanceValue(id: "timeline.nameTimeSpacing", title: "名前と時刻の間隔の最小値", range: 0...100, step: 1, spacing: .s2)
    /// 本文の行と行のあいだに足す余白。
    public static let bodyLineSpacing = AppearanceValue(id: "timeline.bodyLineSpacing", title: "行間", range: 0...100, step: 1, defaultValue: 0, role: .free)
    /// 注意書きのボックスの、注意書きの文字と開くボタンのあいだ。
    public static let spoilerButtonSpacing = AppearanceValue(id: "timeline.spoilerButtonSpacing", title: "文字と開くボタンのあいだ", range: 0...100, step: 1, spacing: .s1)
    /// 添付ファイルが1つの投稿で、縦長の画像をどこまで縦長のまま出すか（幅÷高さ）。これより縦長なものは上下を切り落とす。
    public static let mediaTallestAspectRatio = AppearanceValue(id: "timeline.mediaTallestAspectRatio", title: "1枚の画像の最も縦長な比率（幅÷高さ）", range: 0.1...4, step: 0.05, defaultValue: 0.75, unit: .ratio)
    /// リンクカードの説明の行数。0なら説明を出さない。
    public static let linkCardDescriptionLines = AppearanceValue(id: "timeline.linkCardDescriptionLines", title: "説明の行数", range: 0...10, step: 1, defaultValue: 1, unit: .lines)
    /// リンクカードの、サイト名・タイトル・説明の行どうしのあいだ。
    public static let linkCardLineSpacing = AppearanceValue(id: "timeline.linkCardLineSpacing", title: "行のあいだ", range: 0...100, step: 1, spacing: .s1)
    /// 名前やブーストした人の行が入りきらないときに、行末をぼかす幅。
    public static let nameFadeWidth = AppearanceValue(id: "timeline.nameFadeWidth", title: "入りきらない名前の行末をぼかす幅", range: 0...100, step: 1, defaultValue: 20, role: .free)
    /// 時刻の前の公開範囲の記号と、時刻のgap。
    public static let visibilitySymbolSpacing = AppearanceValue(id: "timeline.visibilitySymbolSpacing", title: "公開範囲の記号と時刻の間隔", range: 0...100, step: 1, spacing: .s1)
    /// 時刻の前の編集済みの「*」と、時刻のgap。
    public static let editedMarkSpacing = AppearanceValue(id: "timeline.editedMarkSpacing", title: "“*”と時刻の間隔", range: 0...100, step: 1, defaultValue: 0, role: .free)
    /// 本文の引用とリストの、1段あたりのインデントの、本文の文字の大きさに対する割合。1で1文字分。引用の縦線も、この中に引く。
    public static let quoteIndent = AppearanceValue(id: "timeline.quoteIndentRatio", title: "引用とリストのインデント", range: 0...10, step: 0.1, defaultValue: 1, unit: .ratio)
    /// 本文の引用の段落の頭に、深さの数だけ引く縦線の太さ。0なら引かない。
    public static let quoteBarWidth = AppearanceValue(id: "timeline.quoteBarWidth", title: "引用の縦線の太さ", range: 0...100, step: 1, defaultValue: 3, role: .free)
    /// 本文と注意書きのカスタム絵文字の高さの、絵文字の標準の大きさ（絵文字を文字の大きさのまま描いたときの絵の高さ）に対する割合。
    /// 絵文字の大きさと同じ割合なら、同じ高さに描く。
    public static let customEmojiScale = AppearanceValue(id: "timeline.customEmojiScale", title: "カスタム絵文字の倍率", range: 0...4, step: 0.1, defaultValue: 1, unit: .ratio)
    /// 名前の行と名前の上の行のカスタム絵文字の高さの、絵文字の標準の大きさに対する割合。
    public static let nameCustomEmojiScale = AppearanceValue(id: "timeline.nameCustomEmojiScale", title: "カスタム絵文字の倍率", range: 0...4, step: 0.1, defaultValue: 1, unit: .ratio)
    /// 本文と注意書きの、カスタム絵文字でない絵文字の絵の高さの、標準の大きさ（文字の大きさのまま描いたときの絵の高さ）に対する割合。
    /// 0にすると書体の大きさが0ptになり、書体の標準の大きさで描かれるため、下限を0より上にする。
    public static let unicodeEmojiScale = AppearanceValue(id: "timeline.unicodeEmojiScale", title: "絵文字の倍率", range: 0.5...4, step: 0.1, defaultValue: 1, unit: .ratio)
    /// 名前の行と名前の上の行の、カスタム絵文字でない絵文字の絵の高さの、標準の大きさに対する割合。
    public static let nameUnicodeEmojiScale = AppearanceValue(id: "timeline.nameUnicodeEmojiScale", title: "絵文字の倍率", range: 0.5...4, step: 0.1, defaultValue: 1, unit: .ratio)
    /// 本文が、先頭のメンションを除いて絵文字だけのとき、本文の絵文字の大きさ（`unicodeEmojiScale`と`customEmojiScale`）に掛ける倍率。1なら大きくしない。
    public static let emojiOnlyScale = AppearanceValue(id: "timeline.emojiOnlyScale", title: "絵文字だけのときの絵文字の倍率", range: 1...4, step: 0.1, defaultValue: 2, unit: .ratio)
    /// 絵文字だけの本文を大きくする、絵文字の数の上限。これより多ければ大きくしない。0なら大きくしない。
    public static let emojiOnlyLimit = AppearanceValue(id: "timeline.emojiOnlyLimit", title: "大きくする絵文字の数", range: 0...500, step: 1, defaultValue: 10, unit: .count)
    /// 本文を切り始める行数。折り返した行数がこれを超えたら切って「続きを読む」を出す。0なら切らない。決まりはdocs/long-post.mdにある。
    public static let bodyTruncationThreshold = AppearanceValue(id: "timeline.bodyTruncationThreshold", title: "この行数を超えたら切る", range: 0...200, step: 1, defaultValue: 32, unit: .lines)
    /// 本文を切ったときに出す行数。切り始める行数より多ければ、切り始める行数まで出す。
    public static let bodyTruncatedLines = AppearanceValue(id: "timeline.bodyTruncatedLines", title: "切ったときの行数", range: 1...200, step: 1, defaultValue: 15, unit: .lines)
    /// アイコンを角丸の四角にしたときの、radiusの一辺に対する割合。0.5で円になる。
    public static let avatarCornerRatio = AppearanceValue(id: "timeline.avatarCornerRatio", title: "角の丸さ", range: 0...0.5, step: 0.05, defaultValue: 0.2, unit: .percent)
    /// 注意書きのボックスのradius。
    public static let spoilerCornerRadius = AppearanceValue(id: "timeline.spoilerCornerRadius", title: "ボックスの角の半径", range: 0...100, step: 1, defaultValue: 8, role: .free)
    /// 本文などと、自分のフィルターに一致したことを示す注記のあいだ。
    public static let filterNoteSpacing = AppearanceValue(id: "timeline.filterNoteSpacing", title: "注記とのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// 添付ファイルが1つの投稿で、横長の画像をどこまで横長のまま出すか（幅÷高さ）。これより横長なものは左右を切り落とす。
    public static let mediaWidestAspectRatio = AppearanceValue(id: "timeline.mediaWidestAspectRatio", title: "1枚の画像の最も横長な比率（幅÷高さ）", range: 1...10, step: 0.1, defaultValue: 3, unit: .ratio)
    /// 添付ファイルを本文の右に並べるときの、正方形の一辺。2つ以上を重ねるときも、重なり全体をこの正方形に収める。
    public static let mediaBesideSide = AppearanceValue(id: "timeline.mediaBesideSide", title: "右に並べるときの大きさ", range: 0...200, step: 1, defaultValue: 64, role: .free)
    /// リンクカードのタイトルの行数。
    public static let linkCardTitleLines = AppearanceValue(id: "timeline.linkCardTitleLines", title: "タイトルの行数", range: 1...10, step: 1, defaultValue: 1, unit: .lines)
    /// リンクカードの画像の幅の上限の、カードの幅に対する割合。画像はカードの高さの正方形にし、これより広くしない。
    public static let linkCardImageWidthRatio = AppearanceValue(id: "timeline.linkCardImageWidthRatio", title: "画像の幅の上限（カードの幅に対する割合）", range: 0...1, step: 0.05, defaultValue: 0.3, unit: .ratio)
    /// 投票の選択肢の、枠と記号や割合のあいだの左右の余白。
    public static let pollOptionHorizontalPadding = AppearanceValue(id: "timeline.pollOptionHorizontalPadding", title: "選択肢の左右の余白", range: 0...100, step: 1, spacing: .s2)
    /// 投票の選択肢の枠のradius。
    public static let pollOptionCornerRadius = AppearanceValue(id: "timeline.pollOptionCornerRadius", title: "選択肢の角の半径", range: 0...100, step: 1, defaultValue: 8, role: .free)
    /// 投票の最後の選択肢と、票数と締め切りの行のあいだ。
    public static let pollFooterSpacing = AppearanceValue(id: "timeline.pollFooterSpacing", title: "選択肢と票数のあいだ", range: 0...100, step: 1, spacing: .s2)

    /// 投稿本文の段落と段落のあいだの余白。
    public static let paragraphSpacing = AppearanceValue(id: "timeline.paragraphSpacing", title: "段落のあいだ", range: 0...100, step: 1, spacing: .s2)
    /// 投稿の左に出すアイコンの一辺。
    public static let avatarSize = AppearanceValue(id: "timeline.avatarSize", title: "大きさ", range: 0...200, step: 1, defaultValue: 40, role: .free)
    /// ブーストした人の行に出すアイコンの一辺。
    public static let boosterAvatarSize = AppearanceValue(id: "timeline.boosterAvatarSize", title: "ブーストした人のアイコン", range: 0...200, step: 1, defaultValue: 18, role: .free)
    /// 返信と返信先の行のアイコン同士をつなぐ線の太さ。
    public static let replyLineWidth = AppearanceValue(id: "timeline.replyLineWidth", title: "返信をつなぐ線の太さ", range: 0...20, step: 0.5, defaultValue: 2, role: .free)
    /// 返信をつなぐ線と、アイコンのあいだのgap。
    public static let replyLineGap = AppearanceValue(id: "timeline.replyLineGap", title: "返信をつなぐ線との間隔", range: 0...100, step: 1, spacing: .s1)
    /// 投稿と通知の行で、左のアイコンの列と、右の文字の列のあいだ。
    public static let avatarSpacing = AppearanceValue(id: "timeline.avatarSpacing", title: "文字の列とのあいだ", range: 0...100, step: 1, spacing: .s2)
    /// 名前の上の行の記号と、文字の列のあいだ。ブーストした人のアイコンがあれば、そのアイコンとのあいだになる。
    /// 記号はアイコンの列の右端に揃えず、文字の列からこの幅だけ離して置く。記号どうしの縦の揃いは保たれる。
    public static let contextSymbolSpacing = AppearanceValue(id: "timeline.contextSymbolSpacing", title: "記号との間隔", range: 0...100, step: 1, spacing: .s1)
    /// 名前の上の行で、ブーストした人の名前の部分と、後ろに添える部分のgap。
    public static let contextPartsSpacing = AppearanceValue(id: "timeline.contextPartsSpacing", title: "ブーストした人の名前と添える部分の間隔", range: 0...100, step: 1, spacing: .s1)
    /// 名前の上の行の、ブーストした人のアイコンと文字のgap。
    public static let contextAvatarTextSpacing = AppearanceValue(id: "timeline.contextAvatarTextSpacing", title: "アイコンと文字の間隔", range: 0...100, step: 1, spacing: .s1)
    /// ブーストや固定、通知の種類を示す名前の上の行と、名前の行のあいだ。
    public static let contextSpacing = AppearanceValue(id: "timeline.contextSpacing", title: "名前の行とのあいだ", range: 0...100, step: 1, spacing: .s2)
    /// 投稿の名前の行と本文のあいだ。
    public static let nameBodySpacing = AppearanceValue(id: "timeline.nameBodySpacing", title: "本文とのあいだ", range: 0...100, step: 1, spacing: .s2)
    /// 本文のない投稿で、名前の行と、添付ファイルのサムネイルのあいだ。
    public static let nameMediaSpacing = AppearanceValue(id: "timeline.nameMediaSpacing", title: "本文がないときのメディアとのあいだ", range: 0...100, step: 1, spacing: .s2)
    /// 注意書き（CW）のボックスの内側の余白。
    public static let spoilerPadding = AppearanceValue(id: "timeline.spoilerPadding", title: "ボックスの内側の余白", range: 0...100, step: 1, spacing: .s2)
    /// 注意書き（CW）のボックスと、開いた本文のあいだ。
    public static let spoilerBodySpacing = AppearanceValue(id: "timeline.spoilerBodySpacing", title: "本文とのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// 投稿の本文と、添付ファイルのサムネイルのあいだ。
    public static let bodyMediaSpacing = AppearanceValue(id: "timeline.bodyMediaSpacing", title: "本文とのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// 添付ファイルのサムネイルを並べるときの、サムネイル同士のgap。
    public static let mediaTileSpacing = AppearanceValue(id: "timeline.mediaTileSpacing", title: "サムネイル同士の間隔", range: 0...100, step: 1, spacing: .s1)
    /// 投稿の本文や添付ファイルと、リンクカードのあいだ。
    public static let bodyLinkCardSpacing = AppearanceValue(id: "timeline.bodyLinkCardSpacing", title: "本文とのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// リンクカードの文字の、枠とサムネイルからの余白。
    public static let linkCardPadding = AppearanceValue(id: "timeline.linkCardPadding", title: "内側の余白", range: 0...100, step: 1, spacing: .s2)
    /// 投稿の本文や添付ファイルと、引用とXの投稿のカードのあいだ。
    public static let bodyXPostSpacing = AppearanceValue(id: "timeline.bodyXPostSpacing", title: "投稿の本文とのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// 引用とXの投稿のカードの内側の余白。
    public static let xPostPadding = AppearanceValue(id: "timeline.xPostPadding", title: "内側の余白", range: 0...100, step: 1, spacing: .s2)
    /// 引用とXの投稿のカードの、作者のアイコンと名前のgap。
    public static let xPostAvatarNameSpacing = AppearanceValue(id: "timeline.xPostAvatarNameSpacing", title: "アイコンと名前の間隔", range: 0...100, step: 1, spacing: .s1)
    /// 引用とXの投稿のカードの、作者の行と本文のあいだ。
    public static let xPostHeaderSpacing = AppearanceValue(id: "timeline.xPostHeaderSpacing", title: "作者の行と本文のあいだ", range: 0...100, step: 1, spacing: .s2)
    /// 引用とXの投稿のカードの、本文とメディアのあいだ。
    public static let xPostMediaSpacing = AppearanceValue(id: "timeline.xPostMediaSpacing", title: "本文とメディアのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// 引用とXの投稿のカードの、作者の行に出すアイコンの一辺。
    public static let xPostAvatarSize = AppearanceValue(id: "timeline.xPostAvatarSize", title: "アイコンの大きさ", range: 0...200, step: 1, defaultValue: 18, role: .free)
    /// 本文と投票のあいだ。
    public static let bodyPollSpacing = AppearanceValue(id: "timeline.bodyPollSpacing", title: "本文とのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// 投票の選択肢どうしのあいだ。
    public static let pollOptionSpacing = AppearanceValue(id: "timeline.pollOptionSpacing", title: "選択肢のあいだ", range: 0...100, step: 1, spacing: .s2)
    /// 投票の選択肢の、文字の上下の余白。
    public static let pollOptionPadding = AppearanceValue(id: "timeline.pollOptionPadding", title: "選択肢の上下の余白", range: 0...100, step: 1, spacing: .s2)

    /// 本文などと、絵文字のリアクションの列のあいだ。
    public static let bodyReactionsSpacing = AppearanceValue(id: "timeline.bodyReactionsSpacing", title: "本文とのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// 絵文字のリアクションのボタンどうしのあいだ。折り返した行のあいだも同じにする。
    public static let reactionSpacing = AppearanceValue(id: "timeline.reactionSpacing", title: "ボタンのあいだ", range: 0...100, step: 1, spacing: .s1)
    /// 絵文字のリアクションのボタンの、文字の上下の余白。
    public static let reactionPadding = AppearanceValue(id: "timeline.reactionPadding", title: "ボタンの上下の余白", range: 0...100, step: 1, spacing: .s2)
    /// 絵文字のリアクションのボタンの、文字の左右の余白。
    public static let reactionHorizontalPadding = AppearanceValue(id: "timeline.reactionHorizontalPadding", title: "ボタンの左右の余白", range: 0...100, step: 1, spacing: .s2)

    // MARK: アクションバー

    /// 本文などと、アクションバーのあいだ。
    public static let actionBarSpacing = AppearanceValue(id: "actionBar.spacing", title: "本文とのあいだ", range: 0...100, step: 1, spacing: .s3)
    /// アクションバーのボタンのアイコンの大きさ。0ptの記号は書体の標準の大きさで描かれるため、1ptを下限にする。
    public static let actionBarIconSize = AppearanceValue(id: "actionBar.iconSize", title: "アイコンの大きさ", range: 1...100, step: 1, defaultValue: 14, role: .free)
    /// アクションバーのボタンの、アイコンの上下の余白。ボタンのヒット領域の高さは、アイコンにこの余白を足したものになる。
    public static let actionBarPadding = AppearanceValue(id: "actionBar.padding", title: "ボタンの上下の余白", range: 0...100, step: 1, defaultValue: 0, role: .free)

    // MARK: お気に入りとブーストの光

    /// 下の端から照らす光の高さ。光は行の中にだけ伸ばす。ライトでHDRを使わずに描くときは、`ReactionGlow.Style`でこの高さを縮める。
    public static let reactionGlowHeight = AppearanceValue(id: "reactionGlow.height", title: "光の高さ", range: 0...200, step: 2, defaultValue: 64, role: .free)
    public static let reactionGlowDarkOpacity = AppearanceValue(id: "reactionGlow.darkOpacity", title: "光の不透明度（ダークモード）", range: 0...1, step: 0.05, defaultValue: 0.4, unit: .percent)
    /// ライトでHDRで描くときの不透明度。HDRを使わずに描くときは、`ReactionGlow.Style`でこの不透明度を下げる。
    public static let reactionGlowLightOpacity = AppearanceValue(id: "reactionGlow.lightOpacity", title: "光の不透明度（ライトモード）", range: 0...1, step: 0.05, defaultValue: 0.95, unit: .percent)
    /// 左半分のブーストと右半分のお気に入りの光を、真ん中で混ぜる幅。0でくっきり分ける。
    public static let reactionGlowBlendWidth = AppearanceValue(id: "reactionGlow.blendWidth", title: "真ん中で2色を混ぜる幅", range: 0...400, step: 4, defaultValue: 48, role: .free)
    /// 光に添えるアイコンの大きさ。散らすときは、これを基準に大きさを変える。
    /// 0ptの記号は書体の標準の大きさで描かれ、小さくしたつもりが大きくなるため、文字と同じく1ptを下限にする。
    public static let reactionGlowIconSize = AppearanceValue(id: "reactionGlow.iconSize", title: "アイコンの大きさ", range: 1...200, step: 1, defaultValue: 8, role: .free)
    /// 光に添えるアイコンの不透明度。光より目立たせないため、既定では薄くする。
    public static let reactionGlowIconOpacity = AppearanceValue(id: "reactionGlow.iconOpacity", title: "アイコンの不透明度", range: 0...1, step: 0.05, defaultValue: 0.6, unit: .percent)

    public static let groups: [AppearanceGroup] = [
        AppearanceGroup(id: "row", title: "余白", values: [rowPaddingTop, rowPaddingBottom, rowPaddingLeading, rowPaddingTrailing]),
        AppearanceGroup(id: "context", title: "名前の上の行", values: [contextText, contextSecondaryText, contextPartsSpacing, contextLabelText, boosterAvatarSize, contextSymbolSpacing, contextAvatarTextSpacing, contextSpacing]),
        AppearanceGroup(id: "avatar", title: "アイコン", values: [avatarSize, avatarCornerRatio, avatarSpacing, replyLineWidth, replyLineGap]),
        AppearanceGroup(id: "name", title: "名前の行", values: [namePrimaryText, nameSecondaryText, timeText, namePartsSpacing, nameStackSpacing, nameTimeSpacing, visibilitySymbolSpacing, editedMarkSpacing, nameFadeWidth, nameUnicodeEmojiScale, nameCustomEmojiScale, nameBodySpacing, nameMediaSpacing]),
        AppearanceGroup(id: "body", title: "本文", values: [bodyText, bodyLineSpacing, paragraphSpacing, quoteIndent, quoteBarWidth, unicodeEmojiScale, customEmojiScale, emojiOnlyScale, emojiOnlyLimit, bodyTruncationThreshold, bodyTruncatedLines, filterNoteText, filterNoteSpacing]),
        AppearanceGroup(id: "spoiler", title: "注意書き", values: [spoilerButtonText, spoilerButtonSpacing, spoilerPadding, spoilerCornerRadius, spoilerBodySpacing]),
        AppearanceGroup(id: Self.mediaGroupID, title: Self.mediaGroupTitle, values: [bodyMediaSpacing, mediaTileSpacing, mediaTallestAspectRatio, mediaWidestAspectRatio, mediaBesideSide]),
        AppearanceGroup(id: "linkCard", title: "リンクカード", values: [linkCardTitleText, linkCardDetailText, linkCardTitleLines, linkCardDescriptionLines, linkCardLineSpacing, linkCardImageWidthRatio, bodyLinkCardSpacing, linkCardPadding]),
        // Xの投稿のカードも同じ値を使うが、Xの投稿は設定でオンにしたときだけ出すため、名前には書かない。
        AppearanceGroup(id: Self.xPostGroupID, title: "引用", values: [xPostNameText, xPostBodyText, xPostAvatarSize, xPostAvatarNameSpacing, xPostHeaderSpacing, xPostMediaSpacing, xPostPadding, bodyXPostSpacing]),
        AppearanceGroup(id: "poll", title: "投票", values: [pollFooterText, bodyPollSpacing, pollOptionSpacing, pollOptionPadding, pollOptionHorizontalPadding, pollOptionCornerRadius, pollFooterSpacing]),
        // 列はサーバーが絵文字のリアクションに対応しているときだけ出るが、設定はアカウントによらないので、いつも並べる。
        AppearanceGroup(id: "reactions", title: "絵文字のリアクション", values: [reactionText, bodyReactionsSpacing, reactionSpacing, reactionPadding, reactionHorizontalPadding]),
        AppearanceGroup(id: Self.actionBarGroupID, title: "アクションバー", values: [actionBarSpacing, actionBarIconSize, actionBarPadding]),
        AppearanceGroup(id: "reactionGlow", title: "お気に入りとブーストの光", values: [reactionGlowHeight, reactionGlowDarkOpacity, reactionGlowLightOpacity, reactionGlowBlendWidth, reactionGlowIconSize, reactionGlowIconOpacity]),
    ]

    public static let values: [AppearanceValue] = groups.flatMap(\.values)

    /// 引用とXの投稿のカードの部品の区画。
    public static let xPostGroupID = "xPost"
    public static let mediaGroupID = "media"
    public static let mediaGroupTitle = "メディア"

    /// アクションバーの区画。見本では、いつも出す設定でなくてもアクションバーを出す。
    public static let actionBarGroupID = "actionBar"
}
