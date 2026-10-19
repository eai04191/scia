/// HDRの画像と動画を描く明るさ。
public enum MediaDynamicRange: String, CaseIterable, Sendable {
    /// HDRのメディアもSDRの明るさに収める。
    case standard
    /// HDRのまま、まわりのボタンや文字と並んでも眩しすぎないよう明るさを抑える。
    case constrainedHigh
    /// 画面の明るさの上限まで使う。
    case high
}

extension MediaDynamicRange {
    /// 明るさの順。SDRがいちばん暗く、HDRがいちばん明るい。
    private var brightness: Int {
        switch self {
        case .standard: 0
        case .constrainedHigh: 1
        case .high: 2
        }
    }

    /// HDRのメディアの一覧のサムネイルに、HDRの札を出すか。開くと一覧より明るくなることを、前もって知らせるために出す。
    /// - Parameters:
    ///   - list: ビューア以外の明るさ。
    ///   - viewer: ビューアの明るさ。
    public static func marksHDR(list: MediaDynamicRange, viewer: MediaDynamicRange) -> Bool {
        viewer.brightness > list.brightness
    }
}
