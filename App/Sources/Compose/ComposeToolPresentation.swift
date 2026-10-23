import SciaCore

/// 投稿欄のボタンと＋のメニュー、並びの設定画面に出す、項目の名前と印。
extension ComposeToolItem: MenuItemPresentable {
    var title: String {
        switch self {
        case .visibility: "公開範囲"
        case .media: "メディアを添付"
        case .expand: "広げて書く"
        case .spoiler: "注意書き"
        case .poll: "投票"
        case .linkTitle: "リンクにタイトルを付ける"
        case .customEmoji: "カスタム絵文字"
        case .customize: "カスタマイズ"
        case .mention: "メンション"
        case .hashtag: "ハッシュタグ"
        }
    }

    var note: String? {
        switch self {
        case .spoiler: "添付があれば、添付も閲覧注意にします。注意書きを空にすると、閲覧注意だけを付けます"
        case .poll: "本文の下に投票の欄を出します。メディアの添付とは一緒に付けられません"
        case .linkTitle: "本文のURLを選ぶと、リンク先のページのタイトルを読み、URLの前に入れます。URLが行の頭にあれば、タイトルを1行にします"
        case .customEmoji: "サーバーのカスタム絵文字を並べたシートを出します。もう一度押すとキーボードに戻ります"
        case .customize: "この並びを変える画面を開きます。隠しても、設定の「投稿欄のボタン」から変えられます"
        case .mention: "本文のカーソルの位置に半角の@を入れ、返信先の人や前にメンションした人を候補に出します"
        case .hashtag: "本文のカーソルの位置に半角の#を入れ、プロフィールのタグや最近使ったタグを候補に出します"
        default: nil
        }
    }

    var symbolName: String {
        switch self {
        case .visibility: "globe"
        case .media: "photo.on.rectangle"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .spoiler: "exclamationmark.triangle"
        case .poll: "chart.bar.doc.horizontal"
        case .linkTitle: "link.badge.plus"
        case .customEmoji: "face.smiling"
        case .customize: "slider.horizontal.3"
        case .mention: "at"
        case .hashtag: "number"
        }
    }

    static var moreBoundaryTitle: String { "＋ボタン" }
    static var moreBoundaryNote: String { "これより上の項目は＋の中に入れ、下の項目はボタンの行に＋の右から並べます。行に入りきらない項目は＋の中に入ります" }
    static var moreBoundarySymbolName: String { "plus.circle" }
    /// ＋のメニューは項目が少なく、ボタンの行は横並びの区切り線に関わらず横に並ぶため、足させない。
    static var supportsRowSeparators: Bool { false }
}
