/// HDRの画像と動画を描く明るさ。
public enum MediaDynamicRange: String, CaseIterable, Sendable {
    /// HDRのメディアもSDRの明るさに収める。
    case standard
    /// HDRのまま、まわりのボタンや文字と並んでも眩しすぎないよう明るさを抑える。
    case constrainedHigh
    /// 画面の明るさの上限まで使う。
    case high
}
