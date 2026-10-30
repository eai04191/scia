import SciaCore
import UIKit

/// 一覧のサムネイル、リンクカードの画像、プロフィールの画像を長押ししたときと、投稿のメニューのカスタム絵文字の、メディアのメニュー。決まりはdocs/menus.mdの「メディアのメニュー」にある。
extension TimelineViewController {
    /// 長押しした場所にあるメディア。
    struct MediaMenuTarget {
        let attachment: MediaAttachment
        /// 持ち上げて見せるビュー。共有のシートの起点と、見出しのプレビューにも使う。
        /// 投稿のメニューから選ぶカスタム絵文字は、画面に1つのビューとして描いていないためnilにし、共有のシートは画面の真ん中か一覧から出す。
        let source: (any MediaViewerSource)?
        /// `source`がないときに、共有のシートの見出しに添える画像。
        var preview: UIImage?
        /// タップしたときと同じく、ビューアで開く。
        let open: @MainActor () -> Void

        init(attachment: MediaAttachment, source: (any MediaViewerSource)?, preview: UIImage? = nil, open: @escaping @MainActor () -> Void) {
            self.attachment = attachment
            self.source = source
            self.preview = preview
            self.open = open
        }
    }

    /// `point`（一覧の座標）にある、ぼかしていないサムネイルかリンクカードの画像。なければnil。
    /// リンクカードの画像は、開ける状態のときだけ触れられるため、触れたビューをたどった中に画像があるときだけ返す。
    func mediaMenuTarget(at point: CGPoint, in cell: UICollectionViewCell) -> MediaMenuTarget? {
        var view = cell.hitTest(collectionView.convert(point, to: cell), with: nil)
        var touchedCardImage = false
        while let current = view, current !== cell {
            if let tile = current as? MediaTileView {
                return mediaMenuTarget(of: tile)
            }
            if current is LinkCardThumbnailView {
                touchedCardImage = true
            }
            if let card = current as? LinkCardView {
                guard touchedCardImage, let image = card.menuImage else { return nil }
                return MediaMenuTarget(attachment: image.attachment, source: image.thumbnail) { [weak card] in
                    card?.openImageFromMenu()
                }
            }
            view = current.superview
        }
        return nil
    }

    /// 長押しで出す、`entry`の`target`のメディアのメニュー。投稿のメニューは、その「投稿」に入れる。出す項目がなければnil。
    /// - Parameter groups: 組む並び。nilなら設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func mediaMenu(for target: MediaMenuTarget, entry: TimelineEntry, id: ItemID, groups: MenuLayout<MediaMenuItem>.Groups? = nil) -> UIMenu? {
        builtMediaMenu(for: target, entry: entry, id: id, groups: groups)?.menu
    }

    func builtMediaMenu(for target: MediaMenuTarget, entry: TimelineEntry, id: ItemID, groups: MenuLayout<MediaMenuItem>.Groups? = nil) -> BuiltMenu<MediaMenuCommand>? {
        let subject = Self.status(of: entry).map { OperationStatus.Subject($0.displayed) }
        return builtMediaMenu(for: target, subject: subject, statusMenu: statusMenu(for: entry, id: id), groups: groups)
    }

    private func mediaMenuTarget(of tile: MediaTileView) -> MediaMenuTarget? {
        guard let attachment = tile.menuAttachment else { return nil }
        return MediaMenuTarget(attachment: attachment, source: tile) { [weak tile] in
            tile?.onOpen?()
        }
    }

    /// - Parameters:
    ///   - subject: メディアの投稿。共有や保存の失敗を「最近の失敗」に残すときに添える。プロフィールの画像ならnil。
    ///   - statusMenu: 投稿の投稿のメニュー。「投稿」のサブメニューにする。プロフィールの画像ならnil。
    func mediaMenu(for target: MediaMenuTarget, subject: OperationStatus.Subject?, statusMenu: BuiltMenu<StatusMenuCommand>?, groups: MenuLayout<MediaMenuItem>.Groups? = nil) -> UIMenu? {
        builtMediaMenu(for: target, subject: subject, statusMenu: statusMenu, groups: groups)?.menu
    }

    func builtMediaMenu(for target: MediaMenuTarget, subject: OperationStatus.Subject?, statusMenu: BuiltMenu<StatusMenuCommand>?, groups: MenuLayout<MediaMenuItem>.Groups? = nil) -> BuiltMenu<MediaMenuCommand>? {
        let tree = mediaMenuTree(for: target, statusMenu: statusMenu?.root.children)
        guard let root = tree.menu(groups: groups ?? settings.mediaMenuLayout.groups) else { return nil }
        let attachment = target.attachment
        let preview = target.preview
        let open = target.open
        let renderer = MenuRenderer<MediaMenuCommand> { [weak self, weak source = target.source] command in
            switch command {
            case .status(let command):
                statusMenu?.renderer.perform(command)
            case .open:
                open()
            case .copyValue(let value):
                UIPasteboard.general.string = value
                self?.showTextCopiedNotice()
            case .share, .saveToPhotos, .showAltText, .translateText, .url:
                self?.performMediaMenu(command, target: MediaMenuTarget(attachment: attachment, source: source, preview: preview, open: open), subject: subject)
            }
        } customIcon: { icon in
            statusMenu?.renderer.customIcon(icon)
        }
        return BuiltMenu(root: root, renderer: renderer) { statusMenu?.didRender() }
    }

    /// メディアのメニューの木。`target`で行える項目を、今の状態から決める。
    /// - Parameter statusMenu: 投稿の投稿のメニューの中身。「投稿」のサブメニューにする。
    func mediaMenuTree(for target: MediaMenuTarget, statusMenu: [MenuNode<StatusMenuCommand>]?) -> MediaMenuTree {
        let attachment = target.attachment
        let fileURL = attachment.url ?? attachment.remoteUrl
        var tree = MediaMenuTree(kind: attachment.type, attachment: attachment)
        tree.open = true
        if fileURL != nil {
            if case .unknown = attachment.type {
                // アプリで開けない種類のファイルは、ビューアと同じく、ファイルの代わりにURLを共有する。
                tree.share = true
            } else if mediaTransfers != nil {
                tree.share = true
                tree.saveToPhotos = true
            }
        }
        if let description = attachment.description, !description.isEmpty {
            tree.showAltText = true
        }
        tree.fileURL = fileURL
        tree.linkBrowser = settings.linkBrowser
        tree.statusMenu = statusMenu
        return tree
    }

    /// メディアのメニューで押された項目を行う。「投稿」の中の項目は、投稿のメニューが行う。
    func performMediaMenu(_ command: MediaMenuCommand, target: MediaMenuTarget, subject: OperationStatus.Subject?) {
        let attachment = target.attachment
        let source = target.source
        let fileURL = attachment.url ?? attachment.remoteUrl
        switch command {
        case .open:
            target.open()
        case .share:
            guard let fileURL else { return }
            if case .unknown = attachment.type {
                URLSharing.presentShareSheet(for: fileURL, from: self) { $0.sourceItem = source ?? self.collectionView }
            } else {
                mediaTransfers?.start(.share, MediaTransfers.Target(url: fileURL, kind: attachment.type, subject: subject), from: source, preview: source?.loadedThumbnail ?? target.preview)
            }
        case .saveToPhotos:
            // アプリで開けない種類のファイルは、写真に保存しない。
            guard let fileURL else { return }
            if case .unknown = attachment.type { return }
            mediaTransfers?.start(.save, MediaTransfers.Target(url: fileURL, kind: attachment.type, subject: subject), from: source, preview: source?.loadedThumbnail ?? target.preview)
        case .showAltText:
            guard let description = attachment.description, !description.isEmpty else { return }
            frontmostPresented.present(AltTextViewController.sheet(text: description), animated: true)
        case .url(let command):
            mediaURLHandlers(source: source).perform(command)
        case .copyValue(let value):
            UIPasteboard.general.string = value
            showTextCopiedNotice()
        case .translateText, .status:
            // 一覧のメディアのメニューは、画像の文字の翻訳を出さない。「投稿」の中の項目は、投稿のメニューが行う。
            break
        }
    }

    /// メディアのメニューのURLの項目。共有のシートは、長押ししたサムネイルから出す。サムネイルがなければ一覧から出す。
    private func mediaURLHandlers(source: (any MediaViewerSource)?) -> URLMenuHandlers {
        URLMenuHandlers(
            linkBrowser: settings.linkBrowser,
            copy: { [weak self] url in URLSharing.copy(url, notifying: self) },
            share: { [weak self, weak source] url in
                guard let self else { return }
                URLSharing.presentShareSheet(for: url, from: self) { $0.sourceItem = source ?? self.collectionView }
            },
            open: { [weak self] url, browser in self?.openURL(url, in: browser) }
        )
    }
}

/// カスタム絵文字の画像の、メディアのメニュー。投稿のメニューの「カスタム絵文字」と、プロフィールの文章のメニューに置く。「投稿」はこのメニューの中なので出さない。
/// 画像は行に描いているアニメーションしない版を、メニューに文字色で塗られないよう元の色のまま置く。まだ届いていなければ、項目のアイコンを置く。
/// メニューを組んだときに読んだ画像を、アイコンと、共有のシートの見出しに添える画像に使う。
@MainActor
final class CustomEmojiMenus {
    private weak var timeline: TimelineViewController?
    /// 絵文字を使った投稿。共有や保存の失敗を「最近の失敗」に残すときに添える。プロフィールの文章ならnil。
    private let subject: OperationStatus.Subject?
    private var images: [URL: UIImage] = [:]

    init(timeline: TimelineViewController, subject: OperationStatus.Subject?) {
        self.timeline = timeline
        self.subject = subject
    }

    /// `:shortcode:`のサブメニュー。出す項目がなければnil。
    func node(for emoji: CustomEmoji) -> MenuNode<MediaMenuCommand>? {
        guard let timeline else { return nil }
        // 使う人が開いたメニューなので、前に読めなかった画像も間隔を待たずに読み直す。
        images[emoji.staticUrl] = timeline.emojiImages.image(for: emoji.staticUrl, retriesNow: true)
        return timeline.mediaMenuTree(for: target(for: emoji), statusMenu: nil).customEmojiSubmenu(emoji, groups: timeline.settings.mediaMenuLayout.groups)
    }

    /// サブメニューのアイコン。動く絵文字は、動かす設定なら動く画像にする。画像がまだ届いていなければnil。
    func icon(for emoji: CustomEmoji) -> UIImage? {
        guard let timeline else { return nil }
        let animation = timeline.settings.animatesCustomEmojis && AnimatedImagePlayback.isAllowed ? timeline.emojiImages.animation(for: emoji.url) : nil
        return animation.flatMap { TimelineViewController.animatedMenuIcon($0.image) } ?? images[emoji.staticUrl].map(TimelineViewController.menuIcon)
    }

    func perform(_ command: MediaMenuCommand, on emoji: CustomEmoji) {
        if case .copyValue(let value) = command {
            UIPasteboard.general.string = value
            timeline?.showTextCopiedNotice()
            return
        }
        timeline?.performMediaMenu(command, target: target(for: emoji), subject: subject)
    }

    private func target(for emoji: CustomEmoji) -> TimelineViewController.MediaMenuTarget {
        let attachment = emoji.attachment
        return TimelineViewController.MediaMenuTarget(attachment: attachment, source: nil, preview: images[emoji.staticUrl]) { [weak timeline, subject] in
            timeline?.openMedia([attachment], at: 0, subject: subject) { _ in nil }
        }
    }
}
