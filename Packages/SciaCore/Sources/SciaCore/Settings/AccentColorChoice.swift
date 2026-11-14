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

    /// タブのアイコンを、アクセントカラーではなく本文の色の濃淡で描くか。タブバーは選んでいないタブを本文の色で描くので、
    /// モノトーンでは選んでいるタブと同じ色に、グレーでは選んでいるタブより濃くなる。そこでこの2つは、選んでいるタブを本文の色、選んでいないタブを一段薄い色で描く。
    public var drawsTabsInTextColors: Bool {
        self == .gray || self == .monochrome
    }

    /// ティントカラーが本文の色と同じで、色だけではオンとオフを見分けられないか。
    public var tintMatchesTextColor: Bool {
        self == .monochrome
    }

    /// 選ぶ画面に出す名前。
    public var title: String {
        switch self {
        case .blue: "ブルー"
        case .indigo: "インディゴ"
        case .purple: "パープル"
        case .pink: "ピンク"
        case .red: "レッド"
        case .orange: "オレンジ"
        case .yellow: "イエロー"
        case .green: "グリーン"
        case .mint: "ミント"
        case .teal: "ティール"
        case .cyan: "シアン"
        case .brown: "ブラウン"
        case .gray: "グレー"
        case .monochrome: "モノトーン"
        }
    }
}
