import SciaCore
import UIKit

/// 投稿にリアクションする絵文字を、投稿欄と同じ絵文字のシートで選ばせる。選んだらシートを閉じて、選んだ絵文字を渡す。
/// 決まりはdocs/emoji-reaction.mdの「絵文字のシート」にある。
@MainActor
final class EmojiReactionPicker {
    private let completion: TextInputCompletion
    private let emojiImages: EmojiImageStore<UIImage>
    private lazy var palette = makePalette()
    private var sheet: EmojiPaletteSheet?
    private var onChoose: ((ReactionEmoji) -> Void)?

    init(completion: TextInputCompletion, emojiImages: EmojiImageStore<UIImage> = AppDependencies.emojiImages) {
        self.completion = completion
        self.emojiImages = emojiImages
    }

    /// シートを開く。開いている間に呼ばれても、重ねて開かない。
    func present(from host: UIViewController, onChoose: @escaping (ReactionEmoji) -> Void) {
        guard sheet == nil else { return }
        self.onChoose = onChoose
        completion.completion.loadEmojisIfNeeded()
        palette.clearQuery()
        updatePalette()
        observePalette()
        let sheet = EmojiPaletteSheet(palette: palette, lowHeight: 340)
        sheet.onDidClose = { [weak self] in
            self?.sheet = nil
            self?.onChoose = nil
        }
        self.sheet = sheet
        sheet.present(from: host)
    }

    private func makePalette() -> EmojiPaletteView {
        let palette = EmojiPaletteView(emojiImages: emojiImages)
        palette.showsDeleteButton = false
        palette.onSelect = { [weak self] emoji in self?.choose(emoji) }
        palette.onRetry = { [weak self] in self?.completion.completion.loadEmojisIfNeeded() }
        palette.onQueryChange = { [weak self] in self?.updatePalette() }
        // パレットは自分の処理を持つので、ここで作ったパレットを直接触ると循環参照になる。持ち主のプロパティから触る。
        palette.onSearchSubmit = { [weak self] in
            guard let self else { return }
            self.palette.clearQuery()
            updatePalette()
            sheet?.endSearch()
        }
        return palette
    }

    private func choose(_ emoji: PaletteEmoji) {
        let chosen = switch emoji {
        case .custom(let custom): ReactionEmoji(name: custom.shortcode, url: custom.url, staticUrl: custom.staticUrl)
        case .standard(let standard): ReactionEmoji(name: standard.emoji)
        }
        completion.recordRecent(emoji)
        let onChoose = onChoose
        sheet?.close(notifiesWillClose: false)
        onChoose?(chosen)
    }

    private func observePalette() {
        withObservationTracking {
            updatePalette()
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                guard self?.sheet != nil else { return }
                self?.observePalette()
            }
        }
    }

    private func updatePalette() {
        completion.updatePalette(palette, recentKeys: completion.recentKeys)
    }
}
