import SciaCore
import UIKit

/// 絵文字のパレットのカスタム絵文字のメニューが使う、セッションの部品。パレットを出す画面を作るところで入れる。
@MainActor
struct EmojiPaletteMenuContext {
    /// コピーしたことと、ダウンロードの進み具合を知らせる先。
    var notices: NoticeCenter?
    /// 共有と写真への保存で、ファイルを落として渡す。nilなら2つの項目を出さない。
    var transfers: MediaTransferCenter?
    /// 開く項目で、ファイルのURLを開く。nilなら開く項目を出さない。
    var openURL: (@MainActor (URL, LinkBrowser) -> Void)?
}

/// 絵文字のパレットでカスタム絵文字を長押ししたときに、カスタム絵文字のメニューを組み、選択された項目を行う。決まりはdocs/menus.mdの「カスタム絵文字のメニュー」にある。
@MainActor
struct EmojiPaletteMenu {
    let context: EmojiPaletteMenuContext
    let tuning: TuningStore
    let settings: AppSettings
    let emojiImages: EmojiImageStore<UIImage>

    func menu(for emoji: ServerEmoji, in palette: EmojiPaletteView) -> UIMenu {
        var tree = CustomEmojiMenuTree(emoji: emoji.emoji)
        tree.open = true
        tree.share = context.transfers != nil
        tree.saveToPhotos = context.transfers != nil
        tree.linkBrowser = settings.linkBrowser
        tree.opensURLs = context.openURL != nil
        tree.display = settings.customEmojiDisplay(of: emoji.emoji)
        tree.isKnownStill = emojiImages.isKnownStill(emoji.url)
        let renderer = MenuRenderer<CustomEmojiMenuCommand> { [weak palette] command in
            guard let palette else { return }
            perform(command, on: emoji, in: palette)
        }
        return renderer.menu(tree.menu(groups: settings.customEmojiMenuLayout.groups))
    }

    private func perform(_ command: CustomEmojiMenuCommand, on emoji: ServerEmoji, in palette: EmojiPaletteView) {
        guard let presenter = palette.window?.rootViewController else { return }
        let target = MediaTransfers.Target(url: emoji.url, kind: .image, subject: nil)
        switch command {
        case .copyShortcode(let text), .copyValue(let text):
            copy(text)
        case .setDisplay(let display):
            settings.setCustomEmojiDisplay(display, of: emoji.emoji)
            show(.customEmojiDisplayChanged(emoji.emoji, to: display))
        case .open:
            open(emoji, from: presenter, closing: palette)
        case .share:
            context.transfers?.start(.share, target, from: nil, preview: preview(of: emoji))
        case .saveToPhotos:
            context.transfers?.start(.save, target, from: nil, preview: preview(of: emoji))
        case .url(let command):
            URLMenuHandlers(
                linkBrowser: settings.linkBrowser,
                copy: { url in
                    UIPasteboard.general.url = url
                    show(.linkCopied)
                },
                share: { [weak palette] url in
                    URLSharing.presentShareSheet(for: url, from: presenter) { $0.sourceItem = palette }
                },
                open: { [weak palette] url, browser in openURL(url, in: browser, closing: palette) },
                openSettings: { _ in }
            ).perform(command)
        case .customize:
            // 設定はパレットのシートの上には重ねず、シートを閉じてから開く。設定を開く側が、閉じ終えるのを待つ。
            palette.closeSheet()
            presenter.openMenuSettings(.customEmojiMenu)
        }
    }

    /// シートの上にビューアを重ねる。絵文字は選ぶ前に見ているので、閉じたらパレットに戻す。
    /// 持ち上げた絵はメニューと一緒に消えていて起点にできないため、投稿のメニューのカスタム絵文字と同じく、画像を動かさずに薄くして開く。
    private func open(_ emoji: ServerEmoji, from presenter: UIViewController, closing palette: EmojiPaletteView) {
        let openURL = context.openURL.map { openURL in
            { @MainActor [weak palette] (url: URL, browser: LinkBrowser) in
                palette?.closeSheet()
                openURL(url, browser)
            }
        }
        MediaViewerOpener(store: AppDependencies.mediaImages, tuning: tuning, transfers: context.transfers, notices: context.notices)
            .open([emoji.emoji.attachment], at: 0, subject: nil, from: presenter, sourceTile: { _ in nil }, openURL: openURL)
    }

    /// 開いた先はパレットのシートの上には重ねず、シートを閉じてから開く。開く側が、閉じ終えるのを待つ。
    private func openURL(_ url: URL, in browser: LinkBrowser, closing palette: EmojiPaletteView?) {
        palette?.closeSheet()
        context.openURL?(url, browser)
    }

    private func preview(of emoji: ServerEmoji) -> UIImage? {
        emojiImages.image(for: EmojiPaletteCell.choice(of: emojiImages).url(of: emoji))
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        show(.textCopied)
    }

    private func show(_ notice: Notice) {
        context.notices?.showTransient(notice, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }
}
