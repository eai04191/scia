/// ボタンやリンクなど、押せるものに付けるアプリのアクセントカラー。システムの色から選び、ライトとダーク、コントラストを上げる設定に合わせた色はシステムに任せる。
public enum AccentColorChoice: String, CaseIterable, Sendable {
    case blue
    case indigo
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case cyan
    case brown
    case gray
    /// ライトでは黒、ダークでは白。本文の文字と同じ色になる。
    case monochrome

    /// 本文のリンクに下線を引く。本文の文字（モノトーン）や控えめな文字（グレー）と色で見分けられないため。
    public var underlinesLinks: Bool {
        switch self {
        case .gray, .monochrome: true
        default: false
        }
    }
}
