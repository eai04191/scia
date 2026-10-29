/// 読めたカスタム絵文字の一覧を、ログインしている間覚えておく。
/// 補完は画面ごとに作るので、プロフィールの編集のように開くたびに作る画面では、絵文字のパレットを開くたびに一覧を読み直し、
/// 読み込み中の段から絵文字のまとまりへ下の段のボタンが組み直されて動いた。覚えた一覧を次の補完に渡し、読み込み中を挟まずに並べる。
@MainActor
public final class CustomEmojiCache {
    /// いちばん新しく読めた一覧。まだ読めていなければnil。
    public private(set) var emojis: [ServerEmoji]?

    public init() {}

    func remember(_ emojis: [ServerEmoji]) {
        self.emojis = emojis
    }
}

extension ComposeCompletion.Sources {
    /// カスタム絵文字の一覧を読めたら、`cache`に覚えさせる。読めなかったときは、前に読めた一覧を残す。
    public func remembering(customEmojisIn cache: CustomEmojiCache) -> Self {
        var sources = self
        let load = customEmojis
        sources.customEmojis = {
            let emojis = try await load()
            await cache.remember(emojis)
            return emojis
        }
        return sources
    }
}
