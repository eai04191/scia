import SciaCore
import UIKit

/// 投稿欄のカスタム絵文字のパレット。シート（`EmojiPaletteSheet`）の中身にする。
///
/// 上に検索欄、真ん中に絵文字、下の段にまとまりへ飛ぶボタンと削除キーを置く。下の段は、検索欄にキーボードを出している間だけキーボードに沿う枠に付け、キーボードの上に来る。
/// 一覧は検索欄と下の段の裏まで伸ばし、重なった上下の端をシステムにぼかさせる。
/// キーボードを出していないときは、iOSのキーボードの地球儀の段と同じく、ホームインジケーターの場所まで下げる。
/// 絵文字は、幅に入るだけの列に左から右、上から下へ並べて縦にスクロールし、まとまり（最近使ったもの、カテゴリー）ごとに見出しを付ける。
final class EmojiPaletteView: UIView, UIInputViewAudioFeedback {
    /// カスタム絵文字の一覧の状態。読み終えるまでと読めなかったときは、カスタム絵文字の場所にこの段を置き、Unicodeの絵文字はそのまま並べる。
    enum CustomEmojiStatus: Equatable {
        case loading
        /// 理由の文言を持つ。押すと読み直す。
        case failed(String)
    }

    enum Content: Equatable {
        case sections([EmojiPaletteSection], customStatus: CustomEmojiStatus?)
        /// 検索の結果。空なら見つからないことを出す。カスタム絵文字の一覧がまだなければ、先頭に状態の段を置く。
        case searchResults([PaletteEmoji], customStatus: CustomEmojiStatus?)
    }

    var onSelect: (PaletteEmoji) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onRetry: () -> Void = {}
    /// 検索語が変わった。
    var onQueryChange: () -> Void = {}
    /// 検索欄でReturnを押した。
    var onSearchSubmit: () -> Void = {}

    /// 一覧の上下の端の効果を、検索欄の下端と下の段の上端ではっきり区切る（`.hard`）か、やわらかくぼかす（`.soft`）か。
    var hardEdgeEffect = false {
        didSet { updateEdgeEffectStyle() }
    }

    /// 下の段の高さ。HIGの勧める44ptに届かなくても、押せなくて困る操作ではないため、絵文字の一覧の広さと見比べて決める。
    var barHeight: CGFloat = 38 {
        didSet {
            guard barHeight != oldValue else { return }
            sectionBarHeight.constant = barHeight
            deleteButtonHeight.constant = barHeight
            updateBottomInset()
        }
    }

    /// 下の段と、シートの下端（キーボードを出していればキーボードの上端）との間。
    var barBottomInset: CGFloat = 12 {
        didSet {
            guard barBottomInset != oldValue else { return }
            sectionBarBottom.constant = -barBottomInset
            updateBottomInset()
        }
    }

    var cellSize: CGFloat = 48 {
        didSet {
            guard cellSize != oldValue else { return }
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    /// Unicodeの絵文字を描く絵。本文と同じく、設定に合わせる。
    var emojiStyle: EmojiStyle = .system {
        didSet {
            guard emojiStyle != oldValue else { return }
            reconfigureVisibleCells(matching: nil)
            rebuildSectionButtons()
        }
    }

    var animatesEmojis = false {
        didSet {
            guard animatesEmojis != oldValue else { return }
            reconfigureVisibleCells(matching: nil)
        }
    }

    /// 打った検索語。前後の空白と`:`は除く。
    var query: String {
        (searchField.text ?? "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }

    let searchField = UISearchTextField()
    private(set) var content: Content = .sections([], customStatus: .loading)
    private var customStatus: CustomEmojiStatus?
    private var sections: [EmojiPaletteSection] = []
    private let emojiImages: EmojiImageStore
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    /// 検索欄の入れ物。一覧の上端に重ね、一覧の端の効果を、検索欄の形に合わせて描かせる。
    private let topBar = UIView()
    /// 下の段の入れ物。一覧の下端に重ね、一覧の端の効果を、この中のボタンの形に合わせて描かせる。
    private let bottomBar = UIView()
    private let sectionBar = UIScrollView()
    private let sectionStack = UIStackView()
    private var sectionButtons: [UIButton] = []
    private var selectedSectionIndex: Int?
    private let deleteButton = UIButton(configuration: .plain())
    private lazy var sectionBarHeight = sectionBar.heightAnchor.constraint(equalToConstant: barHeight)
    private lazy var deleteButtonHeight = deleteButton.heightAnchor.constraint(equalToConstant: barHeight)
    /// 角の丸みに合わせて左右を内側に寄せた枠。
    private lazy var cornerAdaptedGuide = layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
    private lazy var sectionBarBottom = sectionBar.bottomAnchor.constraint(equalTo: keyboardEdge.topAnchor, constant: -barBottomInset)
    /// 下の段と一覧の下端を付ける枠。ふだんはシートの下端に置き、検索欄にキーボードを出している間だけキーボードに沿わせる。
    /// いつもキーボードに沿わせると、プロフィールの編集で入力欄のキーボードを下げながらシートを出したとき、キーボードに沿う枠の上端がシートの上がる間ずっと下端から約40pt上に残り、下がりきってから一度に下端へ移るので、下の段が一覧に重なってから落ちて見えた。
    private let keyboardEdge = UILayoutGuide()
    private lazy var keyboardEdgeAtBottom = keyboardEdge.topAnchor.constraint(equalTo: bottomAnchor)
    private lazy var keyboardEdgeAtKeyboard = keyboardEdge.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
    private let statusLabel = UILabel()

    /// 上下の部品の高さと間隔。
    /// シートの上端から検索欄の上端までの間。上の掴み（シートの上端から5ptほどの位置にある高さ5ptの棒）との間を数pt残す。
    private static let topInset: CGFloat = 15
    private static let searchRowHeight: CGFloat = 36
    private static let gridSpacing: CGFloat = 6
    private static let headerHeight: CGFloat = 28

    private struct Item: Hashable {
        let section: EmojiPaletteSection.Kind
        let key: String
    }

    init(emojiImages: EmojiImageStore) {
        self.emojiImages = emojiImages
        super.init(frame: .zero)
        configureViews()
        emojiImages.addListener(owner: self) { [weak self] urls in
            self?.reconfigureVisibleCells(matching: urls)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 押したときに、システムのキーボードと同じクリック音を鳴らす。
    var enableInputClicksWhenVisible: Bool { true }

    /// 一覧の上に、検索欄の分の余白を足す。いちばん上の見出しが検索欄の下から始まるようにするため。
    private static let topContentInset = topInset + searchRowHeight + gridSpacing

    private func updateEdgeEffectStyle() {
        let style: UIScrollEdgeEffect.Style = hardEdgeEffect ? .hard : .soft
        collectionView.topEdgeEffect.style = style
        collectionView.bottomEdgeEffect.style = style
    }

    /// 一覧の下に、下の段の分の余白を足す。いちばん下の絵文字も下の段より上まで送れるようにするため。
    private func updateBottomInset() {
        collectionView.contentInset.bottom = barHeight + barBottomInset
        collectionView.verticalScrollIndicatorInsets.bottom = barHeight + barBottomInset
    }

    /// 検索語を消して、まとまりごとの一覧に戻す。
    func clearQuery() {
        searchField.text = ""
    }

    func setContent(_ content: Content) {
        guard content != self.content else { return }
        let wasSearchResults = if case .searchResults = self.content { true } else { false }
        self.content = content
        let statusSection = EmojiPaletteSection(kind: .customEmojiStatus, emojis: [])
        switch content {
        case .sections(let sections, let customStatus):
            self.customStatus = customStatus
            var sections = sections
            if customStatus != nil {
                // 最近使ったものの下、カスタム絵文字のまとまりが来る場所に置く。
                let index = sections.first?.kind == .recent ? 1 : 0
                sections.insert(statusSection, at: index)
            }
            self.sections = sections
            statusLabel.text = "並べる絵文字がありません"
            statusLabel.isHidden = !sections.isEmpty
        case .searchResults(let emojis, let customStatus):
            self.customStatus = customStatus
            sections = (customStatus == nil ? [] : [statusSection]) + (emojis.isEmpty ? [] : [EmojiPaletteSection(kind: .searchResults, emojis: emojis)])
            statusLabel.text = "見つかりません"
            statusLabel.isHidden = !emojis.isEmpty
        }
        applySnapshot()
        rebuildSectionButtons()
        // 打つたびに結果が変わるので、先頭に戻す。検索をやめて一覧に戻ったときも先頭から見せる。
        if case .searchResults = content {
            scrollToTop()
        } else if wasSearchResults {
            scrollToTop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSectionBarLeadingInset()
    }

    /// シートに載せたときは、検索欄にキーボードを出していなければシートの下端に置く。前に検索したまま閉じても、ほかの入力欄のキーボードに付いて動かさないため。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        setFollowsKeyboard(searchField.isFirstResponder)
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        guard !searchField.isFirstResponder else { return }
        setFollowsKeyboard(false)
    }

    private func setFollowsKeyboard(_ follows: Bool) {
        guard keyboardEdgeAtKeyboard.isActive != follows else { return }
        // 外してから付ける。両方を同時に有効にすると、満たせない制約になる。
        if follows {
            keyboardEdgeAtBottom.isActive = false
            keyboardEdgeAtKeyboard.isActive = true
        } else {
            keyboardEdgeAtKeyboard.isActive = false
            keyboardEdgeAtBottom.isActive = true
        }
    }

    /// 最初のまとまりのボタンを、角の丸みに合わせて内側に寄せた位置に置く。左端にいるときは、余白が変わっても左端にとどめる。
    private func updateSectionBarLeadingInset() {
        let inset = cornerAdaptedGuide.layoutFrame.minX + 8
        guard sectionBar.contentInset.left != inset else { return }
        let wasAtStart = sectionBar.contentOffset.x <= -sectionBar.contentInset.left
        sectionBar.contentInset.left = inset
        if wasAtStart {
            sectionBar.contentOffset.x = -inset
        }
    }

    // MARK: - 組み立て

    private func configureViews() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "絵文字を検索"
        searchField.accessibilityLabel = "絵文字を検索"
        // Unicodeの絵文字は日本語の言葉でも探すので、ふだんのキーボードにする。
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.returnKeyType = .done
        searchField.delegate = self
        searchField.addAction(UIAction { [weak self] _ in self?.onQueryChange() }, for: .editingChanged)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(searchField)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.register(EmojiPaletteCell.self, forCellWithReuseIdentifier: EmojiPaletteCell.reuseIdentifier)
        collectionView.register(EmojiPaletteStatusCell.self, forCellWithReuseIdentifier: EmojiPaletteStatusCell.reuseIdentifier)
        collectionView.register(EmojiPaletteHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: EmojiPaletteHeader.reuseIdentifier)
        addSubview(collectionView)
        // 一覧を検索欄の裏まで伸ばし、下の段と同じく、重なった端をシステムにぼかさせる。
        let topEdgeInteraction = UIScrollEdgeElementContainerInteraction()
        topEdgeInteraction.scrollView = collectionView
        topEdgeInteraction.edge = .top
        topBar.addInteraction(topEdgeInteraction)
        addSubview(topBar)

        sectionBar.translatesAutoresizingMaskIntoConstraints = false
        sectionBar.showsHorizontalScrollIndicator = false
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        sectionStack.axis = .horizontal
        sectionStack.spacing = 2
        sectionBar.addSubview(sectionStack)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(sectionBar)
        // 一覧を下の段の裏まで伸ばし、重なった端をシステムにぼかさせる。iOS 26のバーの下を一覧が流れるときと同じ見え方にするため。
        let edgeInteraction = UIScrollEdgeElementContainerInteraction()
        edgeInteraction.scrollView = collectionView
        edgeInteraction.edge = .bottom
        bottomBar.addInteraction(edgeInteraction)
        addSubview(bottomBar)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.configuration?.image = UIImage(systemName: "delete.backward")
        deleteButton.configuration?.baseForegroundColor = .label
        deleteButton.accessibilityLabel = "削除"
        deleteButton.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.onDelete()
        }, for: .primaryActionTriggered)
        bottomBar.addSubview(deleteButton)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        let status = UIStackView(arrangedSubviews: [statusLabel])
        status.translatesAutoresizingMaskIntoConstraints = false
        status.axis = .vertical
        status.alignment = .center
        status.spacing = 8
        addSubview(status)
        // 検索をやめてキーボードが下がりきったら、シートの下端に戻す。下がる間はキーボードに付いて動かす。
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide(_:)), name: UIResponder.keyboardDidHideNotification, object: nil)

        // キーボードを出していないとき、キーボードに沿う枠の上端を、下の安全領域の上ではなく下端にする。
        // 安全領域の上に置くと、下の段の下にホームインジケーターの分（34pt）の空きができ、iOSのキーボードより高く見えたため。
        keyboardLayoutGuide.usesBottomSafeArea = false
        updateEdgeEffectStyle()
        collectionView.contentInset.top = Self.topContentInset
        collectionView.verticalScrollIndicatorInsets.top = Self.topContentInset
        updateBottomInset()
        // 下の段はシートの角の丸みに近いので、角の丸みに合わせて左右を内側に寄せた枠に付ける。
        let cornerAdapted = cornerAdaptedGuide
        // 検索欄と下の段の間。一覧の中身が見える場所で、空や見つからないことの文言をこの真ん中に置く。
        let visibleArea = UILayoutGuide()
        addLayoutGuide(visibleArea)
        addLayoutGuide(keyboardEdge)
        NSLayoutConstraint.activate([
            keyboardEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboardEdge.heightAnchor.constraint(equalToConstant: 0),
            keyboardEdgeAtBottom,
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: searchField.bottomAnchor),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset),
            searchField.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            // 一覧と下の段の間は空けない。空けると、どちらにも当たらずに押しても反応しない帯ができる。
            // 一覧は下の段の裏まで伸ばす。下の段の分の余白を足し、いちばん下の絵文字も下の段より上まで送れるようにする。
            collectionView.bottomAnchor.constraint(equalTo: keyboardEdge.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.topAnchor.constraint(equalTo: sectionBar.topAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: keyboardEdge.topAnchor),
            // まとまりのボタンは、シートの左端からスクロールさせる。角の丸みに合わせた位置で切ると、送ったボタンがシートの端より手前でまっすぐ切れて見えたため。
            // 最初のボタンの位置は、中身の前の余白で角の丸みに合わせる（`layoutSubviews`）。
            sectionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionBar.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            // 検索欄にキーボードを出したら、その上に来る。出していなければ、iOSのキーボードの地球儀の段と同じく、ホームインジケーターの場所まで下げる。
            sectionBarBottom,
            sectionBarHeight,
            sectionStack.topAnchor.constraint(equalTo: sectionBar.contentLayoutGuide.topAnchor),
            sectionStack.bottomAnchor.constraint(equalTo: sectionBar.contentLayoutGuide.bottomAnchor),
            sectionStack.leadingAnchor.constraint(equalTo: sectionBar.contentLayoutGuide.leadingAnchor),
            sectionStack.trailingAnchor.constraint(equalTo: sectionBar.contentLayoutGuide.trailingAnchor),
            sectionStack.heightAnchor.constraint(equalTo: sectionBar.frameLayoutGuide.heightAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: cornerAdapted.trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: sectionBar.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 52),
            deleteButtonHeight,
            visibleArea.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            visibleArea.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            status.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: visibleArea.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            // 中央に揃えたスタックの中では、複数行の文言が短い幅で折り返されるので、幅を揃える。
            statusLabel.widthAnchor.constraint(equalTo: status.widthAnchor),
        ])
    }

    /// まとまりごとに、高さに入るだけの行に絵文字を縦に詰め、列を横に並べる。
    private func makeLayout() -> UICollectionViewLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 8
        return UICollectionViewCompositionalLayout(sectionProvider: { [weak self] index, environment in
            let size = self?.cellSize ?? 48
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(Self.headerHeight)),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            // カスタム絵文字の状態の段は、横幅いっぱいの1行にする。
            if let self, sections.indices.contains(index), sections[index].kind == .customEmojiStatus {
                let row = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)), subitems: [row])
                let section = NSCollectionLayoutSection(group: group)
                section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                section.boundarySupplementaryItems = [header]
                return section
            }
            // 幅に入るだけの列に、左から右、上から下へ詰める。
            let columns = max(1, Int((environment.container.effectiveContentSize.width - 16) / size))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(size), heightDimension: .absolute(size)))
            let row = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(size * CGFloat(columns)), heightDimension: .absolute(size)),
                repeatingSubitem: item,
                count: columns
            )
            let section = NSCollectionLayoutSection(group: row)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            section.boundarySupplementaryItems = [header]
            return section
        }, configuration: configuration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<EmojiPaletteSection.Kind, Item> {
        let dataSource = UICollectionViewDiffableDataSource<EmojiPaletteSection.Kind, Item>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            if item.section == .customEmojiStatus {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiPaletteStatusCell.reuseIdentifier, for: indexPath)
                if let self, let cell = cell as? EmojiPaletteStatusCell, let customStatus {
                    cell.configure(customStatus) { [weak self] in self?.onRetry() }
                }
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiPaletteCell.reuseIdentifier, for: indexPath)
            if let self, let cell = cell as? EmojiPaletteCell, let emoji = emoji(at: indexPath) {
                cell.configure(emoji, store: emojiImages, animates: animatesEmojis, emojiStyle: emojiStyle)
            }
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: EmojiPaletteHeader.reuseIdentifier, for: indexPath)
            if let self, let header = header as? EmojiPaletteHeader, sections.indices.contains(indexPath.section) {
                header.label.text = Self.title(of: sections[indexPath.section].kind)
            }
            return header
        }
        return dataSource
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<EmojiPaletteSection.Kind, Item>()
        for section in sections {
            snapshot.appendSections([section.kind])
            if section.kind == .customEmojiStatus {
                // 読み込み中と失敗でキーを変え、状態が変わったら描き直させる。
                let key = switch customStatus { case .failed(let message): "failed:\(message)"; case .loading, nil: "loading" }
                snapshot.appendItems([Item(section: section.kind, key: key)], toSection: section.kind)
                continue
            }
            snapshot.appendItems(section.emojis.map { Item(section: section.kind, key: $0.recentKey) }, toSection: section.kind)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func emoji(at indexPath: IndexPath) -> PaletteEmoji? {
        guard sections.indices.contains(indexPath.section), sections[indexPath.section].emojis.indices.contains(indexPath.item) else { return nil }
        return sections[indexPath.section].emojis[indexPath.item]
    }

    static func title(of kind: EmojiPaletteSection.Kind) -> String {
        switch kind {
        case .recent: "最近使った絵文字"
        case .uncategorized: "カスタム"
        case .category(let name): name
        case .standard(let name): name
        case .searchResults: "検索の結果"
        case .customEmojiStatus: "カスタム"
        }
    }

    /// 届いた画像の絵文字だけを描き直す。nilなら見えているものをすべて描き直す。
    private func reconfigureVisibleCells(matching urls: Set<URL>?) {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let emoji = emoji(at: indexPath), let cell = collectionView.cellForItem(at: indexPath) as? EmojiPaletteCell else { continue }
            if let urls {
                // 画像が届いて描き直すのは、カスタム絵文字だけ。
                guard case .custom(let custom) = emoji, urls.contains(custom.staticUrl) || urls.contains(custom.url) else { continue }
            }
            cell.configure(emoji, store: emojiImages, animates: animatesEmojis, emojiStyle: emojiStyle)
        }
        updateSectionIcons(matching: urls)
    }

    // MARK: - まとまりのボタン

    /// まとまりのボタン。最近使ったものは時計、検索の結果は虫めがね、カテゴリーはその先頭の絵文字の画像をアイコンにする。
    /// 名前の文字にすると、一覧の端の効果（`.soft`）でぼけた絵文字の上に重なって読みにくかった。iOSの絵文字キーボードの下の段もアイコンで並べる。
    /// 名前は、VoiceOverと、長押しの拡大表示で出す。
    private func rebuildSectionButtons() {
        sectionButtons.forEach { $0.removeFromSuperview() }
        sectionButtons = sections.enumerated().map { index, section in
            var configuration = UIButton.Configuration.plain()
            configuration.baseForegroundColor = .secondaryLabel
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            configuration.cornerStyle = .capsule
            configuration.image = sectionIcon(for: section)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.scrollToSection(index) })
            button.accessibilityLabel = Self.title(of: section.kind)
            button.showsLargeContentViewer = true
            button.largeContentTitle = Self.title(of: section.kind)
            button.largeContentImage = configuration.image
            button.addInteraction(UILargeContentViewerInteraction())
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.sectionButtonWidth).isActive = true
            return button
        }
        sectionButtons.forEach(sectionStack.addArrangedSubview)
        selectedSectionIndex = nil
        updateSelectedSection()
    }

    /// まとまりのボタンの幅。アイコンの大きさにかかわらず揃える。
    private static let sectionButtonWidth: CGFloat = 40
    /// まとまりのボタンの絵文字のアイコンの大きさ。
    private static let sectionIconSize: CGFloat = 22

    private func sectionIcon(for section: EmojiPaletteSection) -> UIImage? {
        switch section.kind {
        case .recent:
            return UIImage(systemName: "clock")
        case .searchResults:
            return UIImage(systemName: "magnifyingglass")
        case .customEmojiStatus:
            return UIImage(systemName: customStatus == .loading ? "hourglass" : "exclamationmark.triangle")
        case .uncategorized, .category:
            // 画像が届く前は空けておき、届いたら`updateSectionIcons`で入れる。
            guard case .custom(let emoji) = section.emojis.first, let image = emojiImages.image(for: emoji.staticUrl) else { return nil }
            return Self.icon(from: image)
        case .standard(let title):
            // Unicodeの絵文字のまとまりは、iOSの絵文字キーボードと同じく、記号のアイコンにする。時計や虫めがねと同じ色で並ぶ。
            return UIImage(systemName: Self.standardGroupSymbols[title] ?? "square.grid.2x2")
        }
    }

    /// Unicodeの絵文字のまとまりの名前（`Tools/build-emoji-data.py`の`GROUP_TITLES`）と、まとまりのボタンのアイコン。
    private static let standardGroupSymbols: [String: String] = [
        "顔と感情": "face.smiling",
        "人と体": "hand.raised",
        "動物と自然": "pawprint",
        "食べ物と飲み物": "fork.knife",
        "旅行と場所": "car",
        "活動": "soccerball",
        "物": "lightbulb",
        "記号": "number",
        "旗": "flag",
    ]

    /// 縦横比を保って、アイコンの大きさの枠に収める。絵文字の色のまま描く。
    private static func icon(from image: UIImage) -> UIImage {
        let size = image.size
        let scale = sectionIconSize / max(size.width, size.height, 1)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: sectionIconSize, height: sectionIconSize))
        return renderer.image { _ in
            image.draw(in: CGRect(x: (sectionIconSize - fitted.width) / 2, y: (sectionIconSize - fitted.height) / 2, width: fitted.width, height: fitted.height))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// アイコンの画像が届いたまとまりのボタンに、アイコンを入れる。
    private func updateSectionIcons(matching urls: Set<URL>?) {
        for (index, button) in sectionButtons.enumerated() where sections.indices.contains(index) {
            let section = sections[index]
            guard case .custom(let first) = section.emojis.first, section.kind != .recent, section.kind != .searchResults else { continue }
            if let urls, !urls.contains(first.staticUrl) { continue }
            button.configuration?.image = sectionIcon(for: section)
            button.largeContentImage = button.configuration?.image
        }
    }

    private func scrollToTop() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    /// まとまりの見出しが一覧の上端に来るまでスクロールする。下の端を越える分は、いちばん下までにする。
    private func scrollToSection(_ index: Int) {
        guard sections.indices.contains(index), !sections[index].emojis.isEmpty || sections[index].kind == .customEmojiStatus else { return }
        UIDevice.current.playInputClick()
        collectionView.layoutIfNeeded()
        let header = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: index))
        let top = -collectionView.adjustedContentInset.top
        let bottom = max(top, collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
        let y = min(max((header?.frame.minY ?? 0) + top, top), bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        setSelectedSection(index)
    }

    /// 上端に見えているまとまりのボタンに色を付ける。
    private func updateSelectedSection() {
        let probe = CGPoint(x: 16, y: collectionView.contentOffset.y + collectionView.adjustedContentInset.top + Self.headerHeight + cellSize / 2)
        let index = collectionView.indexPathForItem(at: probe)?.section
            ?? collectionView.indexPathsForVisibleItems.map(\.section).min()
            ?? (sections.isEmpty ? nil : 0)
        setSelectedSection(index)
    }

    private func setSelectedSection(_ index: Int?) {
        guard index != selectedSectionIndex else { return }
        selectedSectionIndex = index
        // 選んでいるまとまりは、アイコンの後ろを薄く塗って示す。絵文字のアイコンは色を変えられないため。
        for (buttonIndex, button) in sectionButtons.enumerated() {
            let selected = buttonIndex == index
            button.configuration?.baseForegroundColor = selected ? .tintColor : .secondaryLabel
            button.configuration?.background.backgroundColor = selected ? .tertiarySystemFill : .clear
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
        guard let index, sectionButtons.indices.contains(index) else { return }
        let button = sectionButtons[index]
        sectionBar.scrollRectToVisible(button.frame.insetBy(dx: -24, dy: 0), animated: true)
    }
}

extension EmojiPaletteView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let emoji = emoji(at: indexPath) else { return }
        UIDevice.current.playInputClick()
        onSelect(emoji)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, scrollView.isTracking || scrollView.isDecelerating else { return }
        updateSelectedSection()
    }
}

/// パレットの絵文字1つ。押している間は、システムの絵文字キーボードのように背景を付ける。
final class EmojiPaletteCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiPaletteCell"
    private let imageView = EmojiImageView(frame: .zero)
    /// Unicodeの絵文字を、文字として描く。
    private let label = UILabel()
    private let highlight = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.backgroundColor = .tertiarySystemFill
        highlight.layer.cornerRadius = 8
        highlight.layer.cornerCurve = .continuous
        highlight.isHidden = true
        contentView.addSubview(highlight)
        contentView.addSubview(imageView)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = contentView.bounds.insetBy(dx: 2, dy: 2)
        let inset = round(contentView.bounds.width * 0.15)
        imageView.frame = contentView.bounds.insetBy(dx: inset, dy: inset)
        label.frame = imageView.frame
    }

    override var isHighlighted: Bool {
        didSet { highlight.isHidden = !isHighlighted }
    }

    func configure(_ emoji: PaletteEmoji, store: EmojiImageStore, animates: Bool, emojiStyle: EmojiStyle) {
        switch emoji {
        case .custom(let custom):
            label.isHidden = true
            imageView.isHidden = false
            imageView.stillImage = store.image(for: custom.staticUrl)
            imageView.animation = animates ? store.animation(for: custom.url) : nil
            accessibilityLabel = custom.shortcode
        case .standard(let standard):
            imageView.isHidden = true
            imageView.stillImage = nil
            imageView.animation = nil
            label.isHidden = false
            // 絵文字の文字の大きさは、枠いっぱいの画像と同じくらいに見えるよう、枠の高さの少し下にする。
            // 文字ではなく、カスタム絵文字の画像と並べる絵として描くため、端末の文字の大きさではなく枠の大きさで決める。
            // swiftlint:disable:next fixed_font_size
            label.font = EmojiFont.font(.systemFont(ofSize: max(bounds.width, 32) * 0.58), style: emojiStyle)
            label.text = standard.emoji
            accessibilityLabel = standard.name
        }
    }
}

extension EmojiPaletteView: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        setFollowsKeyboard(true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSearchSubmit()
        return false
    }
}

/// まとまりの見出し。
private final class EmojiPaletteHeader: UICollectionReusableView {
    static let reuseIdentifier = "EmojiPaletteHeader"
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var accessibilityLabel: String? {
        get { label.text }
        set { label.text = newValue }
    }
}

/// カスタム絵文字の一覧を読んでいる間か、読めなかったときに、カスタム絵文字の場所に置く段。読めなかったときは、文言の下に、押すと読み直すボタンを添える。
private final class EmojiPaletteStatusCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiPaletteStatusCell"
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let retryButton = UIButton(configuration: .tinted())
    private var onRetry: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        retryButton.configuration?.title = "読み直す"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry() }, for: .primaryActionTriggered)
        // 読み込み中はインジケーターと文言を横に、失敗は文言の下に読み直すボタンを置く。カスタム絵文字の中身の代わりに出すので、一覧が空のときやタイムラインの失敗と同じく中央にそろえる。
        let message = UIStackView(arrangedSubviews: [spinner, label])
        message.alignment = .center
        message.spacing = 8
        let stack = UIStackView(arrangedSubviews: [message, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // 縦に並べると、行の幅に合わせて文言を折り返す。
            message.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ status: EmojiPaletteView.CustomEmojiStatus, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        switch status {
        case .loading:
            spinner.startAnimating()
            spinner.isHidden = false
            label.text = "カスタム絵文字を読み込んでいます"
            retryButton.isHidden = true
        case .failed(let message):
            spinner.stopAnimating()
            spinner.isHidden = true
            label.text = message
            retryButton.isHidden = false
        }
    }
}
