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

    public static let items: [TuningItem] = [
        .number(paragraphSpacing),
    ]
}
