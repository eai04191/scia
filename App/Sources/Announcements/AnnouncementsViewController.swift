import SciaCore
import UIKit

/// サーバーのお知らせの一覧。アカウントのメニューから開くシートの中身。決まりはdocs/announcements.mdにある。
///
/// お知らせは多くても数件なので、編集履歴と同じく、スクロールビューに行を縦に積む。
final class AnnouncementsViewController: UIViewController {
    /// 本文のリンクがタップされたときに、その行き先と、リンクのあったお知らせを渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination, Announcement) -> Void)?
    /// 本文のリンクの長押しのメニューの開く項目で、開く場所を決めてURLを開く。
    var onOpenURL: ((URL, LinkBrowser) -> Void)?
    /// リンクのメニューの「プロフィールとして開く」で、リンク先をプロフィールとして探して開く。
    var onOpenProfileURL: ((URL) -> Void)?
    /// メンションの長押しのメニューの、メンションとハンドルをコピーを組むもの。nilなら2つの項目を出さない。
    var userMenuActions: UserMenuActions?
    /// ハッシュタグのメニューの、自分の状態を読んで変える項目を組むもの。nilなら、それらの項目を出さない。
    var hashtagMenuActions: HashtagMenuActions?
    /// アプリ全体のアプリ内通知。
    var notices: NoticeCenter?

    private let model: AnnouncementsModel
    private let completion: TextInputCompletion
    private let settings: AppSettings
    private let emojiImages: EmojiImageStore<UIImage>
    private let tuning: TuningStore
    private let now: () -> Date
    private let scrollView = AnnouncementsScrollView()
    private let stack = UIStackView()
    private var items: [AnnouncementListItem] = []
    private var state = AnnouncementsContentState.loading
    /// 並べているお知らせの行。描き直しても同じお知らせの行は使い回し、押しているボタンの下で行を作り替えない。
    private var entryViews: [Announcement.ID: AnnouncementEntryView] = [:]
    /// 画面に出ている。出ている間に見えた行を既読にする。
    private var isShown = false
    /// いま画面に出ている行。画面の外から入ってきた行だけを既読にする。描き直しや並べ直しのたびに送ると、既読の送信が失敗し続けたときに送り直しが止まらないため。
    private var visibleIDs: Set<Announcement.ID> = []
    /// リンクのメニューを出している。閉じるまで描き直さない。
    private var isLinkMenuShown = false
    private var needsRender = false
    private lazy var emojiPalette = makeEmojiPalette()
    private var emojiSheet: EmojiPaletteSheet?
    /// 絵文字のシートを開いたお知らせ。
    private var reactingAnnouncementID: Announcement.ID?

    init(
        model: AnnouncementsModel,
        completion: TextInputCompletion,
        settings: AppSettings = AppDependencies.settings,
        emojiImages: EmojiImageStore<UIImage> = AppDependencies.emojiImages,
        tuning: TuningStore = AppDependencies.tuning,
        now: @escaping () -> Date = AppDependencies.now
    ) {
        self.model = model
        self.completion = completion
        self.settings = settings
        self.emojiImages = emojiImages
        self.tuning = tuning
        self.now = now
        super.init(nibName: nil, bundle: nil)
        title = "お知らせ"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emojiImages.addListener(whileShownIn: view) { [weak self] _ in self?.render() }
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        scrollView.hidesTopEdgeEffectOnMac()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            guard let task = self?.model.refresh() else {
                refresh?.endRefreshing()
                return
            }
            Task(.withoutRequests) {
                await task.value
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        scrollView.refreshControl = refresh
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])
        // 文字は描いた時点の大きさで持つため、文字の大きさの設定が変わったら描き直す。
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.render()
        }
        model.display = self
        model.appear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isShown = true
        visibleIDs = []
        showVisibleEntries()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isShown = false
        visibleIDs = []
        // シートを閉じたら、開いている間だけ残していた未読の点を消す。
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        model.disappear()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        showVisibleEntries()
    }

    /// 画面の外から入ってきた行を既読にする。
    private func showVisibleEntries() {
        guard isShown else { return }
        let visible = scrollView.bounds
        let shown = Set(entryViews.filter { _, entry in
            entry.superview != nil && entry.convert(entry.bounds, to: scrollView).intersects(visible)
        }.keys)
        for id in shown.subtracting(visibleIDs) {
            model.didShow(id)
        }
        visibleIDs = shown
    }

    // MARK: - 描画

    private func render() {
        guard isViewLoaded else { return }
        guard !isLinkMenuShown else {
            needsRender = true
            return
        }
        setNeedsUpdateContentUnavailableConfiguration()
        let anchor = readingAnchor(keeping: Set(items.compactMap { item in
            if case .announcement(let announcement, _) = item { announcement.id } else { nil }
        }))
        let animatedEmojis = settings.animatesCustomEmojis ? emojiImages : nil
        var views: [UIView] = []
        var used: [Announcement.ID: AnnouncementEntryView] = [:]
        for item in items {
            if !views.isEmpty {
                views.append(separator())
            }
            switch item {
            case .announcement(let announcement, let showsUnreadMark):
                let entry = entryViews[announcement.id] ?? makeEntryView(for: announcement.id)
                entry.apply(content(for: announcement, showsUnreadMark: showsUnreadMark, animatedEmojis: animatedEmojis))
                used[announcement.id] = entry
                views.append(entry)
            case .unreadable:
                views.append(unreadableRow())
            }
        }
        if case .failed(let reason) = state, !items.isEmpty {
            views.insert(contentsOf: [failureRow(reason), separator()], at: 0)
        }
        entryViews = used
        for view in stack.arrangedSubviews where !views.contains(view) {
            view.removeFromSuperview()
        }
        for (index, view) in views.enumerated() {
            stack.insertArrangedSubview(view, at: index)
        }
        restore(anchor)
        view.setNeedsLayout()
    }

    /// 読んでいる行と、その上端の画面上の位置。一番上にいるときはnilで、上に増えたお知らせを見せる。
    /// 描き直したあとも残る行から選ぶ。消える行を基準にすると、消えた分だけ下の行が動くため。
    private func readingAnchor(keeping remaining: Set<Announcement.ID>) -> (id: Announcement.ID, y: CGFloat)? {
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        guard top > 0 else { return nil }
        let entries = entryViews.filter { $0.value.superview != nil && remaining.contains($0.key) }.map { ($0.key, $0.value.frame) }
        guard let (id, frame) = entries.filter({ $0.1.maxY > top }).min(by: { $0.1.minY < $1.1.minY }) else { return nil }
        return (id, frame.minY - scrollView.contentOffset.y)
    }

    /// 上でお知らせが増えたり消えたり高さが変わったりしても、読んでいる行を画面の同じ位置に保つ。操作によらない変化で、読んでいる行を動かさないため（docs/vision.mdの「一覧の動き」）。
    private func restore(_ anchor: (id: Announcement.ID, y: CGFloat)?) {
        guard let anchor, let entry = entryViews[anchor.id], entry.superview != nil else { return }
        scrollView.layoutIfNeeded()
        let minOffset = -scrollView.adjustedContentInset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        scrollView.contentOffset.y = min(max(entry.frame.minY - anchor.y, minOffset), maxOffset)
    }

    private func makeEntryView(for id: Announcement.ID) -> AnnouncementEntryView {
        let entry = AnnouncementEntryView()
        entry.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
        entry.onOpenLink = { [weak self] destination in
            guard let self, let announcement = model.announcements.first(where: { $0.id == id }) else { return }
            onOpenLink?(destination, announcement)
        }
        entry.onToggleReaction = { [weak self] name in self?.model.toggleReaction(name, on: id) }
        entry.onAddReaction = { [weak self] in self?.presentEmojiPalette(for: id) }
        return entry
    }

    private func content(for announcement: Announcement, showsUnreadMark: Bool, animatedEmojis: EmojiImageStore<UIImage>?) -> AnnouncementEntryView.Content {
        let language = settings.glyphLanguageIdentifier()
        let bodyRenderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, paragraphSpacing: 6, emojiImages: emojiImages, language: language)
        let parser = MastodonHTMLParser(mentions: announcement.mentions, tags: announcement.tags, emojis: announcement.emojis)
        let reactionRenderer = RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline), textColor: .label, emojiImages: emojiImages, language: language)
        let reactions = announcement.reactions.map { reaction in
            let customEmoji = reaction.customEmoji
            let text: RichText = customEmoji.map { .plain(":\($0.shortcode):", emojis: [$0]) } ?? .plain(reaction.name, emojis: [])
            return ReactionChipsView.Reaction(
                name: reaction.name,
                emoji: reactionRenderer.render(text),
                count: reaction.displayedCount,
                isMine: reaction.me == true,
                spokenName: customEmoji.map { ":\($0.shortcode):" } ?? reaction.name
            )
        }
        return AnnouncementEntryView.Content(
            date: AnnouncementDateText.text(for: announcement, now: now(), calendar: .current),
            showsUnreadMark: showsUnreadMark,
            body: bodyRenderer.render(parser.parse(announcement.content)),
            reactions: announcement.reactionsAllowed ? reactions : nil,
            animatedEmojis: animatedEmojis
        )
    }

    private func unreadableRow() -> UIView {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.text = "読めなかったお知らせ"
        return padded(label)
    }

    /// 読めていた行を残したまま、シートで開いたときか引っぱったときの失敗を、一覧の上に出す。
    private func failureRow(_ reason: ErrorPresentation) -> UIView {
        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .subheadline).bold
        title.numberOfLines = 0
        title.text = "お知らせを読み込めませんでした"
        let detail = UILabel()
        detail.attributedText = reason.attributedText(textStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        var configuration = UIButton.Configuration.borderedTinted()
        configuration.title = "再試行"
        let retry = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.model.refresh() })
        let column = UIStackView(arrangedSubviews: [title, detail, retry])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 6
        return padded(column)
    }

    private func padded(_ content: UIView) -> UIView {
        let container = UIView()
        container.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.layoutMarginsGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.layoutMarginsGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.layoutMarginsGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.layoutMarginsGuide.trailingAnchor),
        ])
        return container
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        let container = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard items.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        switch self.state {
        case .loading:
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .failed(let reason):
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "お知らせを読み込めませんでした"
            configuration.secondaryAttributedText = reason.attributedText(textStyle: .body)
            configuration.button = .borderedTinted()
            configuration.button.title = "再試行"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.model.refresh() }
            contentUnavailableConfiguration = configuration
        case .loaded:
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "お知らせはありません"
            contentUnavailableConfiguration = configuration
        }
    }

    // MARK: - 絵文字のシート

    private func makeEmojiPalette() -> EmojiPaletteView {
        let palette = EmojiPaletteView(emojiImages: emojiImages)
        palette.showsDeleteButton = false
        palette.onSelect = { [weak self] emoji in self?.choose(emoji) }
        palette.onRetry = { [weak self] in self?.completion.completion.loadEmojisIfNeeded() }
        palette.onQueryChange = { [weak self] in self?.updateEmojiPalette() }
        palette.onSearchSubmit = { [weak self] in
            guard let self else { return }
            emojiPalette.clearQuery()
            updateEmojiPalette()
            emojiSheet?.endSearch()
        }
        return palette
    }

    private func presentEmojiPalette(for id: Announcement.ID) {
        guard emojiSheet == nil else { return }
        reactingAnnouncementID = id
        completion.completion.loadEmojisIfNeeded()
        emojiPalette.clearQuery()
        updateEmojiPalette()
        observeEmojiPalette()
        let sheet = EmojiPaletteSheet(palette: emojiPalette, lowHeight: 340)
        sheet.onDidClose = { [weak self] in
            self?.emojiSheet = nil
            self?.reactingAnnouncementID = nil
        }
        emojiSheet = sheet
        sheet.present(from: navigationController ?? self)
    }

    /// 選んだ絵文字でリアクションして、シートを閉じる。
    private func choose(_ emoji: PaletteEmoji) {
        guard let id = reactingAnnouncementID else { return }
        switch emoji {
        case .custom(let custom):
            model.addReaction(custom.shortcode, customEmoji: CustomEmoji(shortcode: custom.shortcode, url: custom.url, staticUrl: custom.staticUrl), to: id)
        case .standard(let standard):
            model.addReaction(standard.emoji, customEmoji: nil, to: id)
        }
        completion.recordRecent(emoji)
        emojiSheet?.close(notifiesWillClose: false)
    }

    private func observeEmojiPalette() {
        withObservationTracking {
            updateEmojiPalette()
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                guard self?.emojiSheet != nil else { return }
                self?.observeEmojiPalette()
            }
        }
    }

    private func updateEmojiPalette() {
        completion.updatePalette(emojiPalette, recentKeys: completion.recentKeys)
    }
}

extension AnnouncementsViewController: AnnouncementsDisplay {
    func setItems(_ items: [AnnouncementListItem]) {
        self.items = items
        render()
    }

    func setContentState(_ state: AnnouncementsContentState) {
        guard state != self.state else { return }
        self.state = state
        render()
    }
}

extension AnnouncementsViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        showVisibleEntries()
    }
}

/// お知らせを並べるスクロールビュー。リンクやリアクションのボタンを押して少し止めてから引いても、スクロールできるようにする。
private final class AnnouncementsScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

extension AnnouncementsViewController: LinkMenuHost {
    func linkMenuWillShow() {
        isLinkMenuShown = true
    }

    /// メニューを出している間に届いた変化を、閉じてから描く。
    func linkMenuDidHide() {
        isLinkMenuShown = false
        if needsRender {
            needsRender = false
            render()
        }
    }

    /// お知らせのメンションは、一覧の投稿のメンションと結び付けていないため、メニューにアイコンを出さない。
    func mentionMenuIcon(for url: URL) -> UIImage? { nil }

    func showLinkCopiedNotice() {
        notices?.showTransient(.linkCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    func showNotice(_ notice: Notice) {
        notices?.showTransient(notice, duration: tuning.value(of: TuningCatalog.noticeFailureChipDuration))
    }

    func showHandleCopiedNotice(_ part: UserHandlePart) {
        notices?.showTransient(.handleCopied(part), duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    func openURL(_ url: URL, in browser: LinkBrowser) {
        onOpenURL?(url, browser)
    }

    func openProfile(resolving url: URL) {
        onOpenProfileURL?(url)
    }

    /// お知らせの本文には投稿した人がいないため、ハッシュタグのメニューに「ユーザーの投稿」は出ない。
    func openHashtag(_ name: String, of account: Account) {}
}

/// お知らせのシートの入れ物。開いている間は、アプリ内通知のチップの列をシートの上へ出し、ナビゲーションバーのすぐ下に置く。
/// シートの中で起きた失敗（リアクション）や、リンクのメニューのコピーの知らせが、シートに覆われて見えなくならないようにするため。
final class AnnouncementsNavigationController: UINavigationController, NoticeScreen {
    func noticePlacement(below: CGFloat) -> NoticePlacement {
        guard let view = viewIfLoaded, view.window != nil else { return NoticePlacement(top: below) }
        return NoticePlacement(top: view.convert(CGPoint(x: 0, y: navigationBar.frame.maxY + 8), to: nil).y)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NoticeOverlay.installed(in: view.window)?.bringToFront()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        // 閉じ始めたら、列をシートの下へ戻す。閉じる途中のシートの上にチップが浮いたままにならないようにする。
        let window = view.window
        transitionCoordinator?.animate(alongsideTransition: nil) { context in
            guard !context.isCancelled else {
                NoticeOverlay.installed(in: window)?.bringToFront()
                return
            }
            NoticeOverlay.installed(in: window)?.returnBelowPresentations()
        }
    }
}
