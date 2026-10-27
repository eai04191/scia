import SciaCore
import UIKit

extension TimelineViewController {
    /// 閲覧注意の投稿と、注意書きのある投稿と、添付ファイルをぼかすフィルターに一致した投稿は、タップするまで添付ファイルをぼかす。
    /// メニューから隠した投稿もぼかす。ブーストなら元の投稿の添付ファイルを並べる。
    /// 説明にならない代替テキストは、ALTの目印にもビューアにも読み上げにも出さないよう、ここで除いておく。
    /// 本文の右に小さく出す設定なら、重ねて出す。
    func mediaContent(for status: Status) -> MediaGridView.Content? {
        var content = mediaContent(of: status.displayed.mediaAttachments, cover: mediaCover(for: status))
        if settings.mediaArrangement == .besideBody {
            content?.arrangement = .stack(side: settings.value(of: AppearanceCatalog.mediaBesideSide))
            // ブーストでも元の投稿のIDでばらつかせ、同じ投稿はどの行でも同じ形にする。
            content?.stackSeed = status.displayed.id
            content?.tiltsStack = settings.tiltsStackedPhotos
        }
        return content
    }

    /// 添付ファイルをぼかす理由。ぼかさなければnil。
    func mediaCover(for status: Status) -> MediaCover? {
        mediaCovers.cover(for: status, filterTitles: filterWarnings.verdict(for: status).mediaTitles)
    }

    /// `attachments`を並べる中身。引用とXの投稿の囲みの添付ファイルにも使う。囲みは元の投稿の見た目を写すので、設定によらず本文の下に並べる。
    func mediaContent(of attachments: [MediaAttachment], cover: MediaCover?) -> MediaGridView.Content? {
        MediaGridView.Content.make(of: attachments, cover: cover, settings: settings, tuning: tuning, network: network)
    }

    /// ぼかしを外す。同じ投稿をブーストした行と通知の行もまとめて描き直す。ぼかしと中身は同じ大きさのため、行の高さは変わらない。
    /// ほかの画面にもそろえるよう、セッションに知らせる。
    func revealMedia(of status: Status) {
        mediaCovers.reveal(status)
        reconfigureRows(showing: status)
        onChangeMediaCovers?(mediaCovers, status)
    }

    /// ぼかす。開くときと同じく、同じ投稿の行をまとめて描き直し、行の高さは変わらない。ほかの画面にもそろえる。
    func hideMedia(of status: Status) {
        mediaCovers.hide(status)
        reconfigureRows(showing: status)
        onChangeMediaCovers?(mediaCovers, status)
    }

    /// ほかの画面で開いたり隠したりした結果を受け取り、その投稿の行を描き直す。
    func applyMediaCovers(_ covers: MediaCovers, changed status: Status) {
        mediaCovers = covers
        // まだ開いていない画面は、開いたときにこの状態で描く。描き直しのために画面を読み込ませない。
        guard isViewLoaded else { return }
        reconfigureRows(showing: status)
    }

    /// Xの投稿を読み終えた。その投稿へのリンクを出している行を描き直し、リンクカードを囲みに替える。
    /// 行が伸びる分は、リンクカードが届いたときの差し替えと同じ時間で動きでつなぐ。
    func applyXPost(id: String) {
        guard isViewLoaded, tuning.value(of: TuningCatalog.xPostEmbeds) else { return }
        let ids = displayedItemIDs.filter { itemID in
            self.status(for: itemID).flatMap { XPostLink.postID(of: $0.displayed) } == id
        }
        reconfigureAnimatingHeight(Set(ids), duration: tuning.value(of: TuningCatalog.linkCardTransitionDuration))
    }

    /// Xの投稿へのリンクを出す投稿なら、読み終えた投稿の囲みを返す。まだなら読みに行き、読み終えるまではnilを返してリンクカードを出す。
    /// `text`は、コピーや翻訳に渡す本文。本文が空白だけならnil。
    func xPostContent(for status: Status, base: UIListContentConfiguration) -> (content: EmbeddedPostView.Content, media: [MediaAttachment], url: URL, text: String?)? {
        guard tuning.value(of: TuningCatalog.xPostEmbeds), let xPosts, let id = XPostLink.postID(of: status) else { return nil }
        guard let post = xPosts.post(id: id) else {
            xPosts.request(id: id)
            return nil
        }
        // 投稿した人が閲覧注意を付けていれば、Xの添付ファイルもぼかす。ぼかしを外すと、投稿の添付ファイルと同じくそろって外れる。
        let media = mediaContent(of: post.media, cover: mediaCover(for: status))
        let text = post.text.plainText
        return (postContentBuilder.xPost(post, media: media, base: base), media?.attachments ?? [], post.url, text.allSatisfy(\.isWhitespace) ? nil : text)
    }

    private func reconfigureRows(showing status: Status) {
        reconfigure(Set(itemIDs(showing: status)))
    }

    /// 添付ファイルのビューアで覆っている。ビューアは閉じる操作の間に一覧を透かすため、開いている間も一覧を画面に残す。
    /// 閉じ終わりに報告し直せるよう、閉じている途中のビューアは数えない。
    /// ビューアはアプリ内のSafariのシートの上に重ねていることがあるため、重ねている画面をたどって探す。
    var isCoveredByMediaViewer: Bool {
        var presented = presentedViewController
        while let current = presented {
            if let viewer = current as? MediaViewerController { return !viewer.isBeingDismissed }
            presented = current.presentedViewController
        }
        return false
    }

    /// 閉じるときは、タップした行のサムネイルへ戻す。同じ投稿とそのブーストが並んでいると、同じ添付ファイルのサムネイルが複数あるため。
    /// 開いている間にその行が再利用されたら、表示中の別の行から探す。
    /// - Parameter status: 添付ファイルの投稿。共有や保存の失敗を「最近の失敗」に残すときに添える。
    func openMedia(_ attachments: [MediaAttachment], at index: Int, of status: Status, from grid: MediaGridView) {
        openMedia(attachments, at: index, subject: OperationStatus.Subject(status)) { [weak self, weak grid] attachmentID in
            grid?.tile(for: attachmentID) ?? self?.visibleMediaTile(for: attachmentID)
        }
    }

    /// - Parameters:
    ///   - subject: 添付ファイルの投稿。プロフィールの画像ならnil。
    ///   - sourceTile: 開閉の起点にするビューを返す。見つからなければnilを返し、画像を動かさずに薄くして開閉する。
    func openMedia(_ attachments: [MediaAttachment], at index: Int, subject: OperationStatus.Subject?, sourceTile: @escaping @MainActor (MediaAttachment.ID) -> (any MediaViewerSource)?) {
        // ビューアは一覧を残したまま覆うため、覆っている間は、リンクカードを取り直す投稿として見えていないことにする。閉じたら報告し直す。
        onVisibleLinkOnlyCardsChange?([])
        MediaViewerOpener(store: mediaImages, tuning: tuning, transfers: mediaTransfers, notices: notices).open(
            attachments,
            at: index,
            subject: subject,
            // アプリ内のSafariのシートを出していれば、その上に重ねる。
            from: self,
            sourceTile: sourceTile,
            // 一覧は残したままなので表示し直しの通知が来ない。開いている間に届いた新着を、閉じたところで報告する。
            onDismiss: { [weak self] in self?.reportVisibleItems() },
            openURL: { [weak self] url, browser in self?.openURL(url, in: browser) }
        )
    }

    /// 添付ファイルのサムネイルを、表示中のセルから探す。開いている間にセルが再利用されても、閉じるときに今の位置を探せるようにする。
    private func visibleMediaTile(for attachmentID: MediaAttachment.ID) -> MediaTileView? {
        for cell in collectionView.visibleCells {
            let post = cell.contentView as? PostContentView
            let grids = [post?.mediaGrid, post?.embedMediaGrid, (cell.contentView as? NotificationContentView)?.mediaGrid]
            if let tile = grids.lazy.compactMap({ $0?.tile(for: attachmentID) }).first {
                return tile
            }
        }
        return nil
    }
}

extension MediaGridView.Content {
    /// `attachments`を、今の設定とチューニングで並べる中身。添付ファイルがなければnil。一覧の外（編集履歴など）でも同じ見た目にする。
    /// 説明にならない代替テキストは、ALTの目印にもビューアにも読み上げにも出さないよう、ここで除いておく。
    @MainActor
    static func make(of attachments: [MediaAttachment], cover: MediaCover?, settings: AppSettings, tuning: TuningStore, network: NetworkConditionsMonitor) -> Self? {
        guard !attachments.isEmpty else { return nil }
        return MediaGridView.Content(
            attachments: attachments.map { $0.filteringAltText(ignoresUseless: settings.ignoresUselessAltText) },
            cover: cover,
            tallestAspectRatio: settings.value(of: AppearanceCatalog.mediaTallestAspectRatio),
            thumbnailPolicy: MediaThumbnailPolicy(
                enhancement: network.usePolicy(settings: settings).enhancement,
                upscaleTolerance: tuning.value(of: TuningCatalog.mediaThumbnailUpscaleTolerance)
            ),
            spacing: settings.value(of: AppearanceCatalog.mediaTileSpacing),
            widestAspectRatio: settings.value(of: AppearanceCatalog.mediaWidestAspectRatio),
            showsBadges: settings.showsMediaBadges
        )
    }
}
