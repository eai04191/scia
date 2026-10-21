import SciaCore
import UIKit

/// 一覧のサムネイル、リンクカードの画像、プロフィールの画像を長押ししたときの、メディアのメニュー。決まりはdocs/menus.mdの「メディアのメニュー」にある。
extension TimelineViewController {
    /// 長押しした場所にあるメディア。
    struct MediaMenuTarget {
        let attachment: MediaAttachment
        /// 持ち上げて見せるビュー。共有のシートの起点と、見出しのプレビューにも使う。
        let source: any MediaViewerSource
        /// タップしたときと同じく、ビューアで開く。
        let open: @MainActor () -> Void
    }

    /// `point`（一覧の座標）にある、覆っていないサムネイルかリンクカードの画像。なければnil。
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
    func mediaMenu(for target: MediaMenuTarget, entry: TimelineEntry, id: ItemID) -> UIMenu? {
        let subject = Self.status(of: entry).map { OperationStatus.Subject($0.displayed) }
        return mediaMenu(for: target, subject: subject, statusMenu: contextMenu(for: entry, id: id))
    }

    private func mediaMenuTarget(of tile: MediaTileView) -> MediaMenuTarget? {
        guard let attachment = tile.menuAttachment else { return nil }
        return MediaMenuTarget(attachment: attachment, source: tile) { [weak tile] in
            tile?.sendActions(for: .primaryActionTriggered)
        }
    }

    /// - Parameters:
    ///   - subject: メディアの投稿。共有や保存の失敗を「最近の失敗」に残すときに添える。プロフィールの画像ならnil。
    ///   - statusMenu: 投稿の投稿のメニュー。「投稿」のサブメニューにする。プロフィールの画像ならnil。
    func mediaMenu(for target: MediaMenuTarget, subject: OperationStatus.Subject?, statusMenu: UIMenu?) -> UIMenu? {
        let attachment = target.attachment
        let fileURL = attachment.url ?? attachment.remoteUrl
        var menu = MediaMenu(kind: attachment.type, attachment: attachment)
        menu.open = MediaMenu.Command(perform: target.open)
        if let fileURL {
            let source = target.source
            if case .unknown = attachment.type {
                // アプリで開けない種類のファイルは、ビューアと同じく、ファイルの代わりにURLを共有する。
                menu.share = MediaMenu.Command { [weak self, weak source] in
                    guard let self else { return }
                    URLSharing.presentShareSheet(for: fileURL, from: self) { $0.sourceItem = source }
                }
            } else if let mediaTransfers {
                let transferTarget = MediaTransfers.Target(url: fileURL, kind: attachment.type, subject: subject)
                menu.share = MediaMenu.Command { [weak mediaTransfers, weak source] in
                    guard let source else { return }
                    mediaTransfers?.start(.share, transferTarget, from: source)
                }
                menu.saveToPhotos = MediaMenu.Command { [weak mediaTransfers, weak source] in
                    guard let source else { return }
                    mediaTransfers?.start(.save, transferTarget, from: source)
                }
            }
        }
        if let description = attachment.description, !description.isEmpty {
            menu.showAltText = MediaMenu.Command { [weak self] in
                self?.frontmostPresented.present(AltTextViewController.sheet(text: description), animated: true)
            }
        }
        menu.fileURL = fileURL
        menu.urlHandlers = mediaURLHandlers(source: target.source)
        menu.statusMenu = statusMenu
        menu.copyValue = { [weak self] value in
            UIPasteboard.general.string = value
            guard let self else { return }
            showNotice(.textCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
        }
        return menu.menu(layout: settings.mediaMenuLayout)
    }

    /// メディアのメニューのURLの項目。共有のシートは、長押ししたサムネイルから出す。
    private func mediaURLHandlers(source: any MediaViewerSource) -> URLMenuHandlers {
        URLMenuHandlers(
            linkBrowser: settings.linkBrowser,
            copy: { [weak self] url in URLSharing.copy(url, notifying: self) },
            share: { [weak self, weak source] url in
                guard let self else { return }
                URLSharing.presentShareSheet(for: url, from: self) { $0.sourceItem = source }
            },
            open: { [weak self] url, browser in self?.openURL(url, in: browser) }
        )
    }
}
