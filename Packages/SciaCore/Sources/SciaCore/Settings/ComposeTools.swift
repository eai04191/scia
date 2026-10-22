/// 投稿欄のボタンの行か＋のメニューに置く項目。公開範囲や展開のような書き方を変える項目と、添付や注意書きのような部品を足す項目。並びの「その他」の境目を＋のボタンに見立て、境目より上は＋のメニューに入れ、下はボタンの行に＋の右から常に出す。設定を上から読む順が、画面の左から並ぶ順と同じになるようにするため。
/// 決まりはdocs/menus.mdの「投稿欄の＋」にある。
public enum ComposeToolItem: String, MenuItemKind {
    case visibility
    case media
    case expand
    case spoiler
    /// 本文の下に投票の欄を出す。出している間に押すと外す。
    case poll
    /// 本文のURLを選び、リンク先のページのタイトルを付ける。
    case linkTitle
    /// カスタム絵文字を並べたシートを出す。出している間に押すとキーボードに戻す。
    case customEmoji
    /// この並びを変える画面を開く。ほかの項目と同じく、置き場所を選べ、使わなければ隠せる。
    case customize

    /// ＋の中は、上からカスタマイズ、区切り線、リンクにタイトルを付ける、注意書き、投票にし、ボタンの行は「＋ 公開範囲 添付 絵文字 展開」にする。
    /// ＋のメニューはボタンの上に開き、下ほど指が届きやすいので、使う頻度の低いカスタマイズをいちばん上に置く。
    public static let defaultLayout = MenuLayout<ComposeToolItem>(defaultElements: [
        .item(.customize, isVisible: true),
        .separator,
        .item(.linkTitle, isVisible: true),
        .item(.spoiler, isVisible: true),
        .item(.poll, isVisible: true),
        .more,
        .item(.visibility, isVisible: true),
        .item(.media, isVisible: true),
        .item(.customEmoji, isVisible: true),
        .item(.expand, isVisible: true),
    ])
}

/// 項目の、ボタンの行と＋のメニューへの振り分け。
public struct ComposeToolPlacement: Equatable, Sendable {
    /// ボタンの行に、＋の右から出す項目。並びの順。
    public var row: [ComposeToolItem]
    /// ＋のメニューのまとまり。上から並びの順。行に入りきらなかった項目は、最後のまとまりにする。空なら＋を出さない。
    public var menu: [[ComposeToolItem]]

    public var showsAddButton: Bool { !menu.isEmpty }

    public init(row: [ComposeToolItem], menu: [[ComposeToolItem]]) {
        self.row = row
        self.menu = menu
    }

    /// 行に常に出す項目のうち、入りきらない分を、並びの後ろ（行の右端）から＋のメニューの最後へ回す。
    /// ＋のメニューはボタンの上に開くので、最後のまとまりがいちばん＋に近く、設定で境目のすぐ下にあった順に並ぶ。
    /// ＋のメニューが空で、行に全部入るときだけ＋を出さない。＋を出すなら、その幅も行から差し引く。
    /// - Parameters:
    ///   - available: 行のうち、部品を足す項目と＋に使える幅。
    ///   - addButtonWidth: ＋のボタンの幅。隣との間隔を含める。
    ///   - width: 項目のボタンの幅。隣との間隔を含める。
    public init(layout: MenuLayout<ComposeToolItem>, available: Double, addButtonWidth: Double, width: (ComposeToolItem) -> Double) {
        let groups = layout.groups
        // 境目より下（`more`）がボタンの行、上（`main`）が＋のメニュー。行では区切り線を数えない。横並びの区切り線も、ふつうの区切り線と同じに扱う。
        let wanted = groups.more.flatMap(\.items)
        let menu = groups.main.map(\.items)
        let widths = wanted.map(width)
        if menu.isEmpty, widths.reduce(0, +) <= available {
            self.init(row: wanted, menu: [])
            return
        }
        var remaining = available - addButtonWidth
        var count = 0
        for itemWidth in widths {
            guard itemWidth <= remaining else { break }
            remaining -= itemWidth
            count += 1
        }
        let overflow = Array(wanted.dropFirst(count))
        self.init(row: Array(wanted.prefix(count)), menu: menu + (overflow.isEmpty ? [] : [overflow]))
    }
}
