/// プロフィールの自己紹介を、どこまで出してから「さらに表示」で広げるか。
public enum ProfileNoteLength: String, CaseIterable, Sendable {
    /// `collapsedLineCount`行で折りたたむ。
    case collapsed
    /// 最初から全文を出す。
    case full

    /// 折りたたむときの行数。
    public static let collapsedLineCount = 3

    /// 折りたたむ行数。全文を出すならnil。
    public var lineLimit: Int? {
        switch self {
        case .collapsed: Self.collapsedLineCount
        case .full: nil
        }
    }

    /// 設定の選択肢の名前。
    public var title: String {
        switch self {
        case .collapsed: "\(Self.collapsedLineCount)行"
        case .full: "すべて"
        }
    }
}
