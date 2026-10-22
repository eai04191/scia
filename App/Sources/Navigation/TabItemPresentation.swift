import SciaCore

/// タブバーと、タブの並びの設定画面に出す名前と印。
extension TabItem: MenuItemPresentable {
    var title: String {
        switch self {
        case .home: "ホーム"
        case .local: "ローカル"
        case .federated: "連合"
        case .notifications: "通知"
        case .bookmarks: "ブックマーク"
        case .favourites: "お気に入り"
        }
    }

    var note: String? { nil }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .local: "person.2"
        case .federated: "globe"
        case .notifications: "bell"
        case .bookmarks: "bookmark"
        case .favourites: "star"
        }
    }

    static var moreBoundaryTitle: String { "切り替えタブ" }
    static var moreBoundaryNote: String { "これより下の項目は、タブバーの最後のタブにまとめ、見出しのメニューで切り替えます" }
    static var moreBoundarySymbolName: String { "rectangle.stack" }
    /// タブは1つずつ並ぶだけで、まとまりを分けるものがないため、区切り線を足させない。
    static var supportsSeparators: Bool { false }
    static var supportsRowSeparators: Bool { false }
    /// タブバーを空にできないため、最後の1つは無効にさせない。
    static var requiresVisibleItem: Bool { true }
}
