/// 好みで決まる値を、デバッグ用のチューニングパネルから実行中に変えられるようにするための定義。
public enum TuningItem: Sendable, Identifiable {
    case number(NumberTuning)
    case toggle(ToggleTuning)

    public var id: String {
        switch self {
        case .number(let tuning): tuning.id
        case .toggle(let tuning): tuning.id
        }
    }
}

/// スライダーで調整する数値。
public struct NumberTuning: Sendable, Identifiable {
    /// 保存に使うキー。項目ごとに一意にする。
    public let id: String
    public let title: String
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double

    public init(id: String, title: String, range: ClosedRange<Double>, step: Double, defaultValue: Double) {
        precondition(range.contains(defaultValue), "\(id)の既定値が範囲外です")
        self.id = id
        self.title = title
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
    }
}

/// スイッチで切り替える真偽値。
public struct ToggleTuning: Sendable, Identifiable {
    /// 保存に使うキー。項目ごとに一意にする。
    public let id: String
    public let title: String
    public let defaultValue: Bool

    public init(id: String, title: String, defaultValue: Bool) {
        self.id = id
        self.title = title
        self.defaultValue = defaultValue
    }
}

/// アプリで使うチューニング項目の一覧。値を足すときは、ここに定義を追加してTuningStoreから読む。
public enum TuningCatalog {
    /// 投稿本文の段落と段落のあいだの余白。
    public static let paragraphSpacing = NumberTuning(
        id: "timeline.paragraphSpacing",
        title: "本文の段落間隔（pt）",
        range: 0...24,
        step: 1,
        defaultValue: 6
    )

    /// ストリーミングで届いた新着を、まとめてタイムラインに挿入する間隔。最初の新着が届いてからこの時間待つ。
    public static let insertionInterval = NumberTuning(
        id: "streaming.insertionInterval",
        title: "新着をまとめて挿入する間隔（秒）",
        range: 0...10,
        step: 0.5,
        defaultValue: 1
    )

    /// 最上部にいるとき、新着を挿入しても最上部に留まり、新着が流れて見えるようにする。
    /// オフなら最上部でも読んでいる位置を保ち、新着件数を出す。
    public static let followsNewArrivalsAtTop = ToggleTuning(
        id: "streaming.followsNewArrivalsAtTop",
        title: "最上部では新着に追従する",
        defaultValue: true
    )

    /// つなぎ直したとき、切れていた間の投稿を手元とつながるまで続けて読むページ数の上限。1ページは40件。
    /// 超えた分はギャップとして残り、近づいたときに読む。
    public static let fillPageLimit = NumberTuning(
        id: "streaming.fillPageLimit",
        title: "再接続で続けて読むページ数",
        range: 1...10,
        step: 1,
        defaultValue: 5
    )

    /// ギャップが表示領域からこの距離（画面の高さの何倍か）まで近づいたら、タップを待たずに読み始める。
    public static let gapAutoLoadDistance = NumberTuning(
        id: "timeline.gapAutoLoadDistance",
        title: "ギャップを自動で読む距離（画面数）",
        range: 0...3,
        step: 0.5,
        defaultValue: 1
    )

    public static let items: [TuningItem] = [
        .number(paragraphSpacing),
        .number(insertionInterval),
        .toggle(followsNewArrivalsAtTop),
        .number(fillPageLimit),
        .number(gapAutoLoadDistance),
    ]
}
