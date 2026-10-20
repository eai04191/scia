import Foundation

/// 本文や名前の絵文字（Unicodeの絵文字）を、どの絵で描くか。カスタム絵文字は、どちらでもサーバーの画像で描く。
public enum EmojiStyle: String, CaseIterable, Sendable {
    /// OSのApple Color Emoji。
    case system
    /// アプリに入れたtwemojiの書体。
    case twemoji
}
