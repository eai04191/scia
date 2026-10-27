/// 「通知の見た目」の項目の一覧。値は「投稿の見た目」と同じく`AppSettings`が持ち、範囲の決め方も`AppearanceCatalog`に揃える。
///
/// 通知の一覧に出るメンションなどの投稿は投稿として扱い、投稿の部品は「投稿の見た目」で決める。ここには、通知のために足す部品
/// （誰が何をしたかの行、種類の記号、まとめた通知のアイコン、お気に入りやブーストで再掲する投稿の縮めた形）だけを置く。
/// 行の余白とアイコンの列の幅も「投稿の見た目」に従う。同じ一覧に並ぶ投稿の行と、文字の列の左端を揃えるため。
/// 文字の大きさは、投稿の本文の文字との差で決める。
public enum NotificationAppearanceCatalog {
    // MARK: まとめた通知

    /// まとめた通知で、誰が何をしたかの行の上に並べるアイコンの一辺。
    public static let groupAvatarSize = AppearanceValue(id: "notification.groupAvatarSize", title: "アイコンの大きさ", range: 0...200, step: 1, defaultValue: 28)
    /// まとめた通知で、並べるアイコン同士のすき間。
    public static let groupAvatarSpacing = AppearanceValue(id: "notification.groupAvatarSpacing", title: "アイコン同士のすき間", range: 0...100, step: 1, defaultValue: 4)
    /// まとめた通知で、並べたアイコンと、誰が何をしたかの行のあいだ。
    public static let groupAvatarHeaderSpacing = AppearanceValue(id: "notification.groupAvatarHeaderSpacing", title: "誰が何をしたかの行とのあいだ", range: 0...100, step: 1, defaultValue: 6)

    // MARK: 誰が何をしたかの行

    /// お気に入りやフォローなどの通知の、誰が何をしたかの行の文字。種類の記号もこの大きさで描く。
    public static let headerText = AppearanceValue(id: "notification.text.header", title: "文字", range: -40...40, step: 1, defaultValue: 1, unit: .textOffset)
    /// 名前の前に差し込むアイコンの一辺の、文字の行の高さに対する割合。
    public static let headerAvatarScale = AppearanceValue(id: "notification.headerAvatarScale", title: "名前の前のアイコンの大きさ（行の高さに対する割合）", range: 0...4, step: 0.1, defaultValue: 0.9, unit: .ratio)
    /// 名前の前に差し込むアイコンと、名前のすき間。
    public static let headerAvatarNameSpacing = AppearanceValue(id: "notification.headerAvatarNameSpacing", title: "名前の前のアイコンと名前のすき間", range: 0...100, step: 1, defaultValue: 4)

    // MARK: 種類の記号

    /// 通知の種類を示す記号と、文字の列のあいだ。記号はアイコンの列の右端に揃えず、文字の列からこの幅だけ離して置く。
    /// メンションなどの名前の上の行の記号も同じ幅で置き、通知の一覧の記号を縦に揃える。
    public static let symbolSpacing = AppearanceValue(id: "notification.symbolSpacing", title: "文字の列とのすき間", range: 0...100, step: 1, defaultValue: 4)

    // MARK: ハンドル

    /// フォローなどの、誰が何をしたかの行だけの通知で、行の下に添えるハンドルの文字。
    public static let accountText = AppearanceValue(id: "notification.text.account", title: "文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 誰が何をしたかの行と、その下に添えるハンドルのあいだ。
    public static let accountSpacing = AppearanceValue(id: "notification.accountSpacing", title: "誰が何をしたかの行とのあいだ", range: 0...100, step: 1, defaultValue: 3)

    // MARK: 再掲する投稿

    /// お気に入りやブーストの通知で、誰が何をしたかの行と、再掲する投稿のあいだ。本文がなく添付ファイルだけの投稿も、同じ余白で添付ファイルを置く。
    public static let quotedSpacing = AppearanceValue(id: "notification.quotedSpacing", title: "誰が何をしたかの行とのあいだ", range: 0...100, step: 1, defaultValue: 7)
    /// 再掲する投稿の本文と注意書きの文字。
    public static let quotedBodyText = AppearanceValue(id: "notification.text.quotedBody", title: "本文の文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// 再掲する投稿の本文を切る行数。誰が何をしたかの行を主役にするため、本文は短く切る。
    public static let quotedBodyLines = AppearanceValue(id: "notification.quotedBodyLines", title: "本文の行数", range: 1...10, step: 1, defaultValue: 2, unit: .lines)
    /// 再掲する本文と、1列に並べるサムネイルのあいだ。
    public static let quotedMediaSpacing = AppearanceValue(id: "notification.quotedMediaSpacing", title: "本文とサムネイルのあいだ", range: 0...100, step: 1, defaultValue: 8)
    /// 再掲する投稿の添付ファイルを1列に並べるサムネイルの一辺。行の幅に収まらない分は横にスクロールして見せる。
    public static let quotedThumbnailSize = AppearanceValue(id: "notification.quotedThumbnailSize", title: "サムネイルの大きさ", range: 0...200, step: 1, defaultValue: 40)
    /// 1列に並べるサムネイル同士のすき間。
    public static let quotedThumbnailSpacing = AppearanceValue(id: "notification.quotedThumbnailSpacing", title: "サムネイル同士のすき間", range: 0...100, step: 1, defaultValue: 4)
    /// 再掲する本文と、結果の形で足す投票のあいだ。
    public static let quotedPollSpacing = AppearanceValue(id: "notification.quotedPollSpacing", title: "本文と投票のあいだ", range: 0...100, step: 1, defaultValue: 8)
    /// 引用のある投稿を再掲するときに、囲みの代わりに一番下に置く1行の文字。
    public static let quotedNoteText = AppearanceValue(id: "notification.text.quotedNote", title: "引用のある投稿を示す行の文字", range: -40...40, step: 1, defaultValue: -2, unit: .textOffset)
    /// 本文などと、引用のある投稿を示す1行のあいだ。
    public static let quotedNoteSpacing = AppearanceValue(id: "notification.quotedNoteSpacing", title: "引用のある投稿を示す行とのあいだ", range: 0...100, step: 1, defaultValue: 8)

    // MARK: メンションなどの名前の上の行

    /// メンションなどの投稿として出す通知で、名前の上に足す、誰が何をしたかの行の文字。
    public static let contextText = AppearanceValue(id: "notification.text.context", title: "文字", range: -40...40, step: 1, defaultValue: 0, unit: .textOffset)
    /// メンションなどの名前の上の行と、投稿の名前の行のあいだ。
    public static let contextSpacing = AppearanceValue(id: "notification.contextSpacing", title: "名前の行とのあいだ", range: 0...100, step: 1, defaultValue: 4)

    /// 通知の行の上から下への並びで並べる。
    public static let groups: [AppearanceGroup] = [
        AppearanceGroup(id: "notification.group", title: "まとめた通知", values: [groupAvatarSize, groupAvatarSpacing, groupAvatarHeaderSpacing]),
        AppearanceGroup(id: "notification.header", title: "誰が何をしたかの行", values: [headerText, headerAvatarScale, headerAvatarNameSpacing]),
        AppearanceGroup(id: "notification.symbol", title: "種類の記号", values: [symbolSpacing]),
        AppearanceGroup(id: "notification.account", title: "フォローなどのハンドル", values: [accountText, accountSpacing]),
        AppearanceGroup(id: "notification.quoted", title: "お気に入りやブーストで再掲する投稿", values: [quotedSpacing, quotedBodyText, quotedBodyLines, quotedMediaSpacing, quotedThumbnailSize, quotedThumbnailSpacing, quotedPollSpacing, quotedNoteText, quotedNoteSpacing]),
        AppearanceGroup(id: "notification.context", title: "メンションなどの名前の上の行", values: [contextText, contextSpacing]),
    ]

    public static let values: [AppearanceValue] = groups.flatMap(\.values)
}
