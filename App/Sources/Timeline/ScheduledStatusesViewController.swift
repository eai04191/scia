import SciaCore
import UIKit

/// 予約した投稿の一覧。予約の日時が近い順に、タイムラインの投稿の行と同じ見た目で並べる。決まりはdocs/tabs.mdの「予約投稿」にある。
/// 行のタップで日時を変え、長押しのメニューに、日時を変える、投稿欄に戻して書き直す、取り消すを置き、取り消すは左へのスワイプでもできる。
@MainActor
final class ScheduledStatusesViewController: UICollectionViewController {
    typealias ContentState = ScheduledStatusesContentState

    var onAppearing: () -> Void = {}
    var onDisappearing: () -> Void = {}
    /// 引っぱって読み直したとき。読み終えるまで更新コントロールを回す。
    var onRefresh: () async -> Void = {}
    var onRetry: () -> Void = {}
    var onReschedule: (ScheduledStatus) -> Void = { _ in }
    var onRewrite: (ScheduledStatus) -> Void = { _ in }
    var onCancel: (ScheduledStatus) -> Void = { _ in }

    /// 並べている予約。予約の日時が近い順。
    private(set) var statuses: [ScheduledStatus] = []
    /// 行に出す自分のアカウント。予約を投稿するのは自分なので、投稿されたときと同じく自分のアイコンと名前を出す。
    var account: Account?
    /// 添付をビューアで開いたときの、保存と共有の受け持ちとアプリ内通知。
    var mediaTransfers: MediaTransferCenter?
    var notices: NoticeCenter?
    /// 注意書きを開いている予約。
    private var expandedSpoilers: Set<ScheduledStatus.ID> = []
    /// 添付のぼかし。タイムラインと同じく、閲覧注意と注意書きのある予約は最初からぼかし、タップで外す。
    private var mediaCovers = MediaCovers()
    private let tuning = AppDependencies.tuning
    private let settings = AppDependencies.settings
    private var contentState = ContentState.loading
    /// 行の日時の書き方（今年でなければ年を書く）を決める今の日付。
    var now: () -> Date
    private let calendar: Calendar
    private lazy var dataSource = makeDataSource()

    init(now: @escaping () -> Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = true
        // 行を消すのは取り消しだけなので、行のメニューと同じく確かめてから取り消す。
        var onCancel: (ScheduledStatus) -> Void = { _ in }
        var statusAt: (IndexPath) -> ScheduledStatus? = { _ in nil }
        configuration.trailingSwipeActionsConfigurationProvider = { indexPath in
            guard let scheduled = statusAt(indexPath) else { return nil }
            let cancel = UIContextualAction(style: .destructive, title: "取り消す") { _, _, completion in
                onCancel(scheduled)
                // 取り消すかは確認で決めるので、行はまだ消さずに戻す。
                completion(false)
            }
            cancel.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [cancel])
        }
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        onCancel = { [weak self] in self?.onCancel($0) }
        statusAt = { [weak self] in self?.status(at: $0) }
        title = "予約投稿"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = dataSource
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { @MainActor in
                await self?.onRefresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        applySnapshot(animatingChanges: false)
        setNeedsUpdateContentUnavailableConfiguration()
        // 行の文字は組み立てたときの大きさで持つので、文字の大きさが変わったら組み立て直す。
        collectionView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UICollectionView, _) in
            self?.reconfigureAll()
        }
        // 名前のカスタム絵文字は、画像が届くまで空けて描くので、届いたら組み立て直す。
        AppDependencies.emojiImages.addListener(owner: self) { [weak self] urls in
            guard let self, let account, !Set(account.emojis.map(\.staticUrl)).isDisjoint(with: urls) else { return }
            reconfigureAll()
        }
    }

    private func reconfigureAll() {
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onAppearing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappearing()
    }

    /// 予約を並べ直す。サーバーが返す順によらず、予約の日時が近い順にする。
    /// - Parameter animatingChanges: 使う人の操作の結果（取り消し、日時の変更）なら、標準の動きで行を閉じたり動かしたりする。読み直しでは動かさない。
    func setStatuses(_ statuses: [ScheduledStatus], animatingChanges: Bool) {
        self.statuses = statuses.sorted { ($0.scheduledAt, $0.id) < ($1.scheduledAt, $1.id) }
        applySnapshot(animatingChanges: animatingChanges && !UIAccessibility.isReduceMotionEnabled)
        setNeedsUpdateContentUnavailableConfiguration()
    }

    func setContentState(_ state: ContentState) {
        contentState = state
        setNeedsUpdateContentUnavailableConfiguration()
    }

    private func status(at indexPath: IndexPath) -> ScheduledStatus? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return statuses.first { $0.id == id }
    }

    private func applySnapshot(animatingChanges: Bool) {
        guard isViewLoaded else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, ScheduledStatus.ID>()
        snapshot.appendSections([0])
        snapshot.appendItems(statuses.map(\.id))
        // 日時を変えた行は、IDが同じでも中身が変わるので描き直す。
        snapshot.reconfigureItems(statuses.map(\.id).filter { dataSource.snapshot().itemIdentifiers.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: animatingChanges)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Int, ScheduledStatus.ID> {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, ScheduledStatus.ID> { [weak self] cell, _, id in
            guard let self, let scheduled = statuses.first(where: { $0.id == id }), let account else { return }
            cell.contentConfiguration = contentConfiguration(for: scheduled, account: account, base: cell.defaultContentConfiguration())
            cell.accessibilityHint = "日時を変えます"
            cell.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "日時を変える") { [weak self] _ in
                    self?.onReschedule(scheduled)
                    return true
                },
                UIAccessibilityCustomAction(name: "投稿欄に戻して書き直す") { [weak self] _ in
                    self?.onRewrite(scheduled)
                    return true
                },
                UIAccessibilityCustomAction(name: "取り消す") { [weak self] _ in
                    self?.onCancel(scheduled)
                    return true
                },
            ]
        }
        return UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        switch contentState {
        case .loading:
            contentUnavailableConfiguration = statuses.isEmpty ? UIContentUnavailableConfiguration.loading() : nil
        case .failed(let presentation):
            guard statuses.isEmpty else {
                contentUnavailableConfiguration = nil
                return
            }
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            configuration.text = "読み込めませんでした"
            configuration.secondaryText = presentation.text
            var button = UIButton.Configuration.borderless()
            button.title = "再読み込み"
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onRetry() }
            contentUnavailableConfiguration = configuration
        case .loaded:
            guard statuses.isEmpty else {
                contentUnavailableConfiguration = nil
                return
            }
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "clock")
            configuration.text = "予約した投稿はありません"
            contentUnavailableConfiguration = configuration
        }
    }

    // MARK: - 行のメニュー

    private func menu(for scheduled: ScheduledStatus) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "日時を変える", image: UIImage(systemName: "calendar.badge.clock")) { [weak self] _ in self?.onReschedule(scheduled) },
            UIAction(title: "投稿欄に戻して書き直す", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onRewrite(scheduled) },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "取り消す", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.onCancel(scheduled) },
            ]),
        ])
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let scheduled = status(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.menu(for: scheduled) })
    }

    /// 行をタップしたら、日時を変える。いちばん使う操作で、下書きを変えないため。
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let scheduled = status(at: indexPath) else { return }
        onReschedule(scheduled)
    }

    // MARK: - 行の中身

    /// タイムラインの投稿の行と同じ部品で、投稿されたときの見た目に組み立てる。時刻の場所には、予約の日時を「日時」の書き方で出す。
    /// アイコンと名前は押せないようにする。予約の一覧から自分のプロフィールを開く理由がないため。
    private func contentConfiguration(for scheduled: ScheduledStatus, account: Account, base: UIListContentConfiguration) -> PostContentConfiguration {
        let params = scheduled.params
        let preview = Status(
            id: scheduled.id,
            createdAt: scheduled.scheduledAt,
            account: account,
            content: "",
            spoilerText: params.spoilerText,
            url: nil,
            mediaAttachments: scheduled.mediaAttachments,
            sensitive: params.sensitive,
            visibility: params.visibility ?? .public
        )
        let builder = PostContentBuilder(tuning: tuning, settings: settings, emojiImages: AppDependencies.emojiImages, mediaImages: AppDependencies.mediaImages, avatarImages: AppDependencies.avatarImages)
        var configuration = builder.configuration(for: preview, base: base)
        // 本文は書いたときのソースの文字なので、HTMLとして読まずに、空白と改行を書いたまま描く。
        // メンションやハッシュタグはリンクにしない。予約はまだ投稿ではなく、サーバーがリンクを作っていないため。
        configuration.body = builder.body(plain: params.text, of: preview, base: base)
        configuration.timeStyle = .absolute
        configuration.showsTime = true
        configuration.reactionGlow = nil
        configuration.context = context(for: params, font: configuration.metrics.contextFont)
        configuration.spoiler?.isCollapsed = !expandedSpoilers.contains(scheduled.id)
        configuration.onToggleSpoiler = { [weak self] in self?.toggleSpoiler(of: scheduled.id) }
        configuration.onRevealMedia = { [weak self] in self?.revealMedia(of: preview) }
        // 投稿されたときと同じく、閲覧注意と注意書きのある予約の添付はぼかす。
        if var media = MediaGridView.Content.make(of: scheduled.mediaAttachments, cover: mediaCovers.cover(for: preview, filterTitles: []), settings: settings, tuning: tuning, network: AppDependencies.network) {
            media.arrange(beside: scheduled.id, settings: settings)
            configuration.media = media
            configuration.onSelectMedia = { [weak self] index, grid in
                self?.openMedia(media.attachments, at: index, from: grid)
            }
        }
        return configuration
    }

    /// 名前の上の行。返信、引用、投票の予約なら、そのことを書く。どれでもなければnil。
    private func context(for params: ScheduledStatus.Params, font: UIFont) -> PostContentConfiguration.Context? {
        let parts: [(symbol: String, text: String)] = [
            params.inReplyToID != nil ? ("arrowshape.turn.up.left", "返信") : nil,
            params.quotedStatusID != nil ? ("quote.bubble", "引用") : nil,
            params.poll != nil ? ("chart.bar.doc.horizontal", "投票") : nil,
        ].compactMap(\.self)
        guard let first = parts.first else { return nil }
        let text = parts.map(\.text).joined(separator: "・")
        return PostContentConfiguration.Context(
            symbolName: first.symbol,
            avatar: nil,
            text: NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]),
            accessibilityText: text,
            opensAccount: false
        )
    }

    /// ぼかしを外す。ぼかしと中身は同じ大きさのため、行の高さは変わらない。
    private func revealMedia(of preview: Status) {
        mediaCovers.reveal(preview)
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(preview.id) else { return }
        snapshot.reconfigureItems([preview.id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func toggleSpoiler(of id: ScheduledStatus.ID) {
        if expandedSpoilers.remove(id) == nil {
            expandedSpoilers.insert(id)
        }
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: !UIAccessibility.isReduceMotionEnabled)
    }

    private func openMedia(_ attachments: [MediaAttachment], at index: Int, from grid: MediaGridView) {
        MediaViewerOpener(store: AppDependencies.mediaImages, tuning: tuning, transfers: mediaTransfers, notices: notices).open(
            attachments,
            at: index,
            subject: nil,
            from: self,
            sourceTile: { [weak grid] id in grid?.tile(for: id) }
        )
    }
}
