import SciaCore
import UIKit

/// 投稿の編集履歴。今の投稿の版から最初の投稿まで、版ごとに1つ前の版との違いを重ねて縦に並べる。
///
/// 開くたびにサーバーから読む。編集は少ないうえ、開いている間に編集されることもまれなため、手元に残さない。
final class EditHistoryViewController: UIViewController {
    private enum State {
        case loading
        case failed(ErrorPresentation)
        case loaded(StatusEditHistory)
    }

    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// 添付ファイルを覆うか。今の投稿の版は、一覧と同じく、使う人が開いた・隠した選択に従う。セッションがほかの画面とそろえる。
    var mediaCovers = MediaCovers()
    /// 添付ファイルをぼかすフィルターのうち、開いた一覧で一致したものの名前。一覧と同じく、全部の版の添付ファイルを覆う。
    var filterTitles: [String] = []
    /// 今の投稿の版の覆いを外したときに、変えたあとの状態と、変えた投稿を渡して呼ぶ。
    var onChangeMediaCovers: ((MediaCovers, Status) -> Void)?
    /// アプリ全体のアプリ内通知。Macのビューアのウィンドウにもチップの列を重ねる。
    var notices: NoticeCenter?
    /// 添付ファイルのビューアで、共有や保存のために落とす処理。
    var mediaTransfers: MediaTransferCenter?

    private let status: Status
    private let fetch: @MainActor () async throws -> [StatusRevision]
    private let describe: @MainActor (any Error) async -> ErrorPresentation
    private let tuning: TuningStore
    private let builder: EditHistoryContentBuilder
    private let mediaImages: MediaImageStore
    private let scrollView: UIScrollView = EditHistoryScrollView()
    private let stack = UIStackView()
    private var state = State.loading
    /// 覆いを外した版。過去の版の添付ファイルと、外した添付ファイルの覆いに使う。
    private var revealedEditNumbers: Set<Int> = []
    /// 並べている版。ビューアを閉じるときに、押したサムネイルを探す。描き直すと入れ替わる。
    private var entryViews: [Int: EditHistoryEntryView] = [:]
    private var loadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - status: 履歴を開く投稿。ブーストなら元の投稿を渡す。
    ///   - fetch: 版を古い順に読む。
    ///   - describe: 読めなかったときに出す理由。
    init(
        status: Status,
        fetch: @escaping @MainActor () async throws -> [StatusRevision],
        describe: @escaping @MainActor (any Error) async -> ErrorPresentation,
        tuning: TuningStore = AppDependencies.tuning,
        settings: AppSettings = AppDependencies.settings,
        emojiImages: EmojiImageStore = AppDependencies.emojiImages,
        mediaImages: MediaImageStore = AppDependencies.mediaImages,
        network: NetworkConditionsMonitor = AppDependencies.network
    ) {
        self.status = status
        self.fetch = fetch
        self.describe = describe
        self.tuning = tuning
        self.mediaImages = mediaImages
        builder = EditHistoryContentBuilder(tuning: tuning, settings: settings, emojiImages: emojiImages, network: network)
        super.init(nibName: nil, bundle: nil)
        title = "編集履歴"
        emojiImages.addListener(owner: self) { [weak self] _ in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
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
        load()
    }

    private func load() {
        state = .loading
        render()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let revisions = try await fetch()
                state = .loaded(StatusEditHistory(
                    revisions: revisions,
                    mentions: status.mentions,
                    tags: status.tags,
                    language: status.language,
                    minimumUnchangedRatio: tuning.value(of: TuningCatalog.editHistoryMinimumUnchangedRatio)
                ))
            } catch is CancellationError {
                return
            } catch {
                state = .failed(await describe(error))
            }
            render()
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        setNeedsUpdateContentUnavailableConfiguration()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entryViews = [:]
        guard case .loaded(let history) = state else { return }
        let contents = builder.contents(
            for: history,
            language: status.language,
            latestCover: latestCover(of: history),
            isHidden: mediaCovers.isHidden(statusID: status.id),
            filterTitles: filterTitles,
            revealedEditNumbers: revealedEditNumbers
        )
        for (index, (entry, content)) in zip(history.entries, contents).enumerated() {
            if index > 0 {
                stack.addArrangedSubview(separator())
            }
            let entryView = EditHistoryEntryView(mediaImages: mediaImages)
            entryView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
            entryView.apply(content)
            entryView.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination) }
            let editNumber = entry.editNumber
            let isLatest = index == 0
            entryView.onRevealMedia = { [weak self] in self?.revealMedia(of: editNumber, isLatest: isLatest) }
            entryView.onSelectMedia = { [weak self] attachments, index, place in
                self?.openMedia(attachments, at: index, of: editNumber, place: place)
            }
            entryViews[editNumber] = entryView
            stack.addArrangedSubview(entryView)
        }
    }

    /// 今の投稿の版の覆い。一覧を読んだあとに閲覧注意を付ける編集がされていることがあるため、手元の投稿ではなく、読んだ最新の版の閲覧注意で決める。
    private func latestCover(of history: StatusEditHistory) -> MediaCover? {
        guard let latest = history.entries.first?.revision else { return nil }
        return mediaCovers.cover(forStatusID: status.id, isSensitive: latest.sensitive || !latest.spoilerText.isEmpty, filterTitles: filterTitles)
    }

    /// 覆いを外す。今の投稿の版なら、一覧の同じ投稿の行もそろえるよう、セッションに知らせる。
    /// 1つの版の覆いは、どれを押してもまとめて外す。
    private func revealMedia(of editNumber: Int, isLatest: Bool) {
        revealedEditNumbers.insert(editNumber)
        if isLatest {
            mediaCovers.reveal(status)
            onChangeMediaCovers?(mediaCovers, status)
        }
        render()
    }

    /// ほかの画面で開いたり隠したりした結果を受け取り、描き直す。
    func applyMediaCovers(_ covers: MediaCovers, changed status: Status) {
        mediaCovers = covers
        guard status.displayed.id == self.status.id else { return }
        // 隠したら、この画面で外した覆いも戻す。隠す選択は過去の版にも当てるため、前に外した版を見えたままにしない。
        if covers.isHidden(statusID: self.status.id) {
            revealedEditNumbers = []
        }
        render()
    }

    /// 閉じるときは、押したサムネイルへ戻す。開いている間に描き直していれば、描き直したあとの同じ場所のサムネイルを探す。
    private func openMedia(_ attachments: [MediaAttachment], at index: Int, of editNumber: Int, place: EditHistoryEntryView.MediaPlace) {
        MediaViewerOpener(store: mediaImages, tuning: tuning, transfers: mediaTransfers, notices: notices).open(
            attachments,
            at: index,
            subject: OperationStatus.Subject(status),
            from: self
        ) { [weak self] attachmentID in
            self?.entryViews[editNumber]?.mediaGrid(at: place)?.tile(for: attachmentID)
        }
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
        switch self.state {
        case .loading:
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .failed(let reason):
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "編集履歴を読めませんでした"
            configuration.secondaryAttributedText = reason.attributedText(textStyle: .body)
            configuration.button = .borderedTinted()
            configuration.button.title = "再試行"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
            contentUnavailableConfiguration = configuration
        case .loaded:
            contentUnavailableConfiguration = nil
        }
    }
}

/// 編集履歴の版を並べるスクロールビュー。本文のリンクを押して少し止めてから引いても、スクロールできるようにする。
final class EditHistoryScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is LinkHitArea || super.touchesShouldCancel(in: view)
    }
}
