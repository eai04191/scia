public import Foundation

/// カスタム絵文字の2つの画像。サーバーは、元の画像（動くことがある）と、動かない版を別のURLで配る。
public protocol EmojiImageURLs {
    var url: URL { get }
    var staticUrl: URL { get }
}

extension CustomEmoji: EmojiImageURLs {}
extension ServerEmoji: EmojiImageURLs {}

extension EmojiImageURLs {
    /// `urls`（`EmojiImageStore.addListener`が知らせる、届いた画像のURL）に、この絵文字の画像があるか。
    /// 描く場所によって、元の画像と動かない版のどちらを読むかが違うので、両方を見る。
    public func hasImage(in urls: Set<URL>) -> Bool {
        urls.contains(url) || urls.contains(staticUrl)
    }
}

extension Sequence where Element: EmojiImageURLs {
    public func hasImage(in urls: Set<URL>) -> Bool {
        contains { $0.hasImage(in: urls) }
    }
}

/// 絵文字を描く場所が、2つの画像のどちらを読むか（docs/animated-custom-emoji.mdの「コマの読み方」）。
/// 動かす場所は元の画像だけを読み、動かない絵文字もその最初のコマで描く。動かさない場所は動かない版だけを読む。
/// 1つの絵文字のために2つの画像を読まないため。
public struct EmojiImageChoice: Sendable {
    public let animates: Bool
    /// 起動したときに、大きすぎて動かせないと分かっていた元の画像は、動かす場所でも、動かない版で描く。
    let oversized: OversizedEmojiRecord?

    public init(animates: Bool, oversized: OversizedEmojiRecord?) {
        self.animates = animates
        self.oversized = oversized
    }

    /// 動かさない場所。
    public static var still: EmojiImageChoice { EmojiImageChoice(animates: false, oversized: nil) }

    /// 描くのに読む画像のURL。
    public func url(of emoji: some EmojiImageURLs) -> URL {
        animates && oversized?.wasKnownAtLaunch(emoji.url) != true ? emoji.url : emoji.staticUrl
    }

    /// 動かすなら、アニメーションを求めるURL。
    public func animationURL(of emoji: some EmojiImageURLs) -> URL? {
        url(of: emoji) == emoji.url && animates ? emoji.url : nil
    }
}
