import SciaCore
import UIKit

/// 投稿欄のカスタム絵文字のパレット。シート（`EmojiPaletteSheet`）の中身にする。
///
/// 上に検索欄、真ん中に絵文字、下の段にまとまりへ飛ぶボタンと削除キーを置く。下の段は、検索欄にキーボードを出している間だけキーボードに沿う枠に付け、キーボードの上に来る。
/// 絵文字のリストは検索欄と下の段の裏まで伸ばし、重なった上下の端をシステムにぼかさせる。
/// キーボードを出していないときは、iOSのキーボードの地球儀の段と同じく、ホームインジケーターの場所まで下げる。
/// 絵文字は、幅に入るだけの列に左から右、上から下へ並べて縦にスクロールし、まとまり（最近使ったもの、カテゴリー）ごとに見出しを付ける。
final class EmojiPaletteView: UIView, UIInputViewAudioFeedback {
    /// カスタム絵文字のリストの状態。読み終えるまでと読めなかったときは、カスタム絵文字の場所にこの段を置き、Unicodeの絵文字はそのまま並べる。
    enum CustomEmojiStatus: Equatable {
        case loading
        /// 理由の文言を持つ。押すと読み直す。
        case failed(ErrorPresentation)
    }

    enum Content: Equatable {
        case sections([EmojiPaletteSection], customStatus: CustomEmojiStatus?)
        /// 検索の結果。空なら見つからないことを出す。カスタム絵文字のリストがまだなければ、先頭に状態の段を置く。
        case searchResults([PaletteEmoji], customStatus: CustomEmojiStatus?)
    }

    var onSelect: (PaletteEmoji) -> Void = { _ in }
    var onDelete: () -> Void = {}
    /// カスタム絵文字を長押ししたときに、持ち上げた絵の下に出すメニュー。nilなら絵だけを出す。
    var menu: ((ServerEmoji) -> UIMenu?)?
    /// パレットを載せているシートを閉じる。メニューから、シートの上に重ねない画面（設定、ブラウザ）へ移るときに使う。載せたシートが入れる。
    var closeSheet: () -> Void = {}
    /// 肌の色を変えられる絵文字に付けている既定の肌の色。検索欄の隣のボタンに出す。
    var defaultSkinTone: EmojiSkinTone = .none {
        didSet {
            guard defaultSkinTone != oldValue else { return }
            updateSkinToneButton()
        }
    }
    /// 検索欄の隣のボタンで、既定の肌の色を選んだ。
    var onDefaultSkinToneChange: (EmojiSkinTone) -> Void = { _ in }
    /// 長押しした2人の絵文字の、選んでいる途中の肌の色。メニューを出している間だけ持つ。
    private var pairSelection: (emoji: StandardEmoji, first: EmojiSkinTone, second: EmojiSkinTone)?
    /// 長押しで持ち上げて見せているUnicodeの絵文字。2人の絵文字で肌の色を選ぶたびに描き直す。
    private weak var glyphPreview: EmojiGlyphPreviewController?
    /// 長押ししたカスタム絵文字を持ち上げて見せる絵の高さ。
    var previewHeight: CGFloat = TuningCatalog.composeEmojiPalettePreviewHeight.defaultValue
    /// 長押しで持ち上げて見せているプレビュー。大きく読み直した画像が届いたら描き直す。
    private weak var preview: EmojiPalettePreviewController?
    /// 削除のボタンを出すか。入力欄に入れずに絵文字を選ぶだけのとき（お知らせのリアクション）は出さない。
    var showsDeleteButton = true {
        didSet { deleteButton.isHidden = !showsDeleteButton }
    }
    var onRetry: () -> Void = {}
    /// 検索語が変わった。
    var onQueryChange: () -> Void = {}
    /// 検索欄でReturnを押した。
    var onSearchSubmit: () -> Void = {}

    /// 絵文字のリストの上下の端の効果を、検索欄の下端と下の段の上端ではっきり区切る（`.hard`）か、やわらかくぼかす（`.soft`）か。
    var hardEdgeEffect = false {
        didSet { updateEdgeEffectStyle() }
    }

    /// 下の段の高さ。HIGの勧める44ptに届かなくても、押せなくて困る操作ではないため、絵文字のリストの広さと見比べて決める。
    var barHeight: CGFloat = 38 {
        didSet {
            guard barHeight != oldValue else { return }
            sectionBarHeight.constant = barHeight
            deleteButtonHeight.constant = barHeight
            updateBottomInset()
        }
    }

    /// 下の段と、シートの下端（キーボードを出していればキーボードの上端）との間。
    /// 下げすぎると、まとまりのボタンを横にスワイプする指がホームインジケーターの操作に取られ、横にスクロールできなかった。
    private let barBottomInset = CGFloat(SpacingScale.s3)

    var cellSize: CGFloat = 48 {
        didSet {
            guard cellSize != oldValue else { return }
            collectionView.collectionViewLayout.invalidateLayout()
            // 読む画像の高さとUnicodeの絵文字の文字の大きさは、組み立てたときの枠で決めるので、新しい枠で組み立て直す。
            collectionView.layoutIfNeeded()
            reconfigureAllCells()
        }
    }

    /// 横長のカスタム絵文字に横に使わせるマスの数の上限。
    var maxSpan = Int(TuningCatalog.composeEmojiPaletteMaxSpan.defaultValue) {
        didSet {
            guard maxSpan != oldValue else { return }
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    /// 横長のカスタム絵文字を、1マスの高さのどこまで縮めて描いてよいか。これより縮むなら、マスを横に足す。
    var minimumHeightFraction = TuningCatalog.composeEmojiPaletteMinimumHeightFraction.defaultValue {
        didSet {
            guard minimumHeightFraction != oldValue else { return }
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    /// Unicodeの絵文字を描く絵。本文と同じく、設定に合わせる。
    var emojiStyle: EmojiStyle = .system {
        didSet {
            guard emojiStyle != oldValue else { return }
            reconfigureAllCells()
            rebuildSectionButtons()
            updateSkinToneButton()
        }
    }

    /// 打った検索語。前後の空白と`:`は除く。
    var query: String {
        (searchField.text ?? "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }

    let searchField = UISearchTextField()
    /// 既定の肌の色を選ぶボタン。検索欄の隣に置く。
    private let skinToneButton = UIButton(configuration: .plain())
    private(set) var content: Content = .sections([], customStatus: .loading)
    private var customStatus: CustomEmojiStatus?
    private var sections: [EmojiPaletteSection] = []
    let emojiImages: EmojiImageStore<UIImage>
    private let glyphImages: EmojiGlyphImageStore
    private let thumbnails: EmojiThumbnails
    private let glyphArchive: EmojiGlyphArchive
    /// 画面に出ている間、小さい静止画を裏で作るのを止めさせる。部品カタログやテストのように、作らせなくてよいパレットではnil。
    private let thumbnailBuilder: EmojiThumbnailBuilder?
    /// `thumbnailBuilder`に、画面に出ていると伝えたか。
    private var isCountedAsShown = false
    private lazy var collectionView: UICollectionView = EmojiPaletteCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    /// スクロールの間に落ちたフレームと、そのフレームに使った処理を数える。違和感レポートで、パレットのスクロールの重さを読むため。
    private let scrollHitches = ScrollHitchMonitor()
    private var scrollStart: (offset: CGFloat, time: CFTimeInterval, screen: String)?
    #if DEBUG
    /// `scia-debug://emoji-palette/section`で動かした移動が終わったときに、落ちたフレームと、そのフレームに使った処理を渡す。
    private var debugJumpCompletion: ((HitchCounter.Summary, FrameWorkTally, (layouts: [Double], configures: [Double])) -> Void)?
    #endif
    var mediaTime: () -> CFTimeInterval = AppDependencies.mediaTime
    private lazy var dataSource = makeDataSource()
    /// 検索欄の入れ物。絵文字のリストの上端に重ね、リストの端の効果を、検索欄の形に合わせて描かせる。
    private let topBar = UIView()
    /// 下の段の入れ物。絵文字のリストの下端に重ね、リストの端の効果を、この中のボタンの形に合わせて描かせる。
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
    /// 下の段と絵文字のリストの下端を付ける枠。ふだんはシートの下端に置き、検索欄にキーボードを出している間だけキーボードに沿わせる。
    /// いつもキーボードに沿わせると、プロフィールの編集で入力欄のキーボードを下げながらシートを出したとき、キーボードに沿う枠の上端がシートの上がる間ずっと下端から約40pt上に残り、下がりきってから一度に下端へ移るので、下の段が絵文字のリストに重なってから落ちて見えた。
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

    init(
        emojiImages: EmojiImageStore<UIImage>,
        glyphImages: EmojiGlyphImageStore = AppDependencies.emojiGlyphImages,
        thumbnails: EmojiThumbnails = AppDependencies.emojiThumbnails,
        glyphArchive: EmojiGlyphArchive = AppDependencies.emojiGlyphArchive,
        thumbnailBuilder: EmojiThumbnailBuilder? = AppDependencies.emojiThumbnailBuilder
    ) {
        self.emojiImages = emojiImages
        self.thumbnails = thumbnails
        self.glyphArchive = glyphArchive
        self.thumbnailBuilder = thumbnailBuilder
        // 小さい静止画をメモリに写す。写すだけで中身は読まないので、すぐ済む。
        thumbnails.load()
        self.glyphImages = glyphImages
        super.init(frame: .zero)
        configureViews()
        glyphImages.addListener(owner: self) { [weak self] request, image in
            self?.glyphDidLoad(request, image)
        }
        // 文字のまま描く絵文字の色は、外観で変わる。
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.reconfigureAllCells()
            self.updateSkinToneButton()
        }
        emojiImages.addListener(owner: self) { [weak self] urls in
            FrameWork.measure("EmojiPaletteView.imagesDidLoad") { self?.reconfigureVisibleCells(showing: urls) }
            self?.preview?.imagesDidLoad(urls)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 押したときに、システムのキーボードと同じクリック音を鳴らす。
    var enableInputClicksWhenVisible: Bool { true }

    /// 絵文字のリストの上に、検索欄の分の余白を足す。いちばん上の見出しが検索欄の下から始まるようにするため。
    private static let topContentInset = topInset + searchRowHeight + gridSpacing

    private func updateEdgeEffectStyle() {
        let style: UIScrollEdgeEffect.Style = hardEdgeEffect ? .hard : .soft
        collectionView.topEdgeEffect.style = style
        collectionView.bottomEdgeEffect.style = style
    }

    /// 絵文字のリストの下に、下の段の分の余白を足す。いちばん下の絵文字も下の段より上まで送れるようにするため。
    private func updateBottomInset() {
        collectionView.contentInset.bottom = barHeight + barBottomInset
        collectionView.verticalScrollIndicatorInsets.bottom = barHeight + barBottomInset
    }

    /// 検索語を消して、まとまりごとの並びに戻す。
    func clearQuery() {
        searchField.text = ""
    }

    func setContent(_ content: Content) {
        guard content != self.content else { return }
        let wasSearchResults = if case .searchResults = self.content { true } else { false }
        let previousPersonal = Self.personalEmojis(in: sections)
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
            statusLabel.text = EmojiPaletteTexts.noEmojis
            statusLabel.isHidden = !sections.isEmpty
        case .searchResults(let emojis, let customStatus):
            self.customStatus = customStatus
            sections = (customStatus == nil ? [] : [statusSection]) + (emojis.isEmpty ? [] : [EmojiPaletteSection(kind: .searchResults, emojis: emojis)])
            statusLabel.text = EmojiPaletteTexts.noResults
            statusLabel.isHidden = !emojis.isEmpty
        }
        applySnapshot()
        reconfigureChangedPersonalEmojis(since: previousPersonal)
        rebuildSectionButtons()
        // 打つたびに結果が変わるので、先頭に戻す。検索をやめてまとまりごとの並びに戻ったときも先頭から見せる。
        if case .searchResults = content {
            scrollToTop()
        } else if wasSearchResults {
            scrollToTop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSectionBarLeadingInset()
        // Unicodeの絵文字のマスが画面に出る前から、描く大きさを渡す。閉じている間に、その大きさで画像を作らせるため。
        if window != nil {
            let side = CGSize(width: cellSize, height: cellSize)
            glyphArchive.use(EmojiPaletteCell.glyphGeometry(cellSize: side, scale: traitCollection.displayScale, style: emojiStyle))
        }
    }

    /// シートに載せたときは、検索欄にキーボードを出していなければシートの下端に置く。前に検索したまま閉じても、ほかの入力欄のキーボードに付いて動かさないため。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if (window != nil) != isCountedAsShown {
            isCountedAsShown = window != nil
            if isCountedAsShown {
                thumbnailBuilder?.paletteDidAppear()
            } else {
                thumbnailBuilder?.paletteDidDisappear()
            }
        }
        // スクロールの途中でシートが閉じると、止まりの通知を受けずに終わる。
        guard window != nil else { return recordScroll() }
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
        searchField.placeholder = EmojiPaletteTexts.search
        searchField.accessibilityLabel = EmojiPaletteTexts.search
        // Unicodeの絵文字は日本語の言葉でも探すので、ふだんのキーボードにする。
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.smartInsertDeleteType = .offOnMac
        searchField.returnKeyType = .done
        searchField.delegate = self
        searchField.addAction(UIAction { [weak self] _ in self?.onQueryChange() }, for: .editingChanged)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(searchField)
        skinToneButton.translatesAutoresizingMaskIntoConstraints = false
        skinToneButton.configuration?.contentInsets = .zero
        skinToneButton.accessibilityLabel = EmojiPaletteTexts.defaultSkinTone
        skinToneButton.showsMenuAsPrimaryAction = true
        topBar.addSubview(skinToneButton)
        updateSkinToneButton()

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.register(EmojiPaletteCell.self, forCellWithReuseIdentifier: EmojiPaletteCell.reuseIdentifier)
        collectionView.register(EmojiPaletteStatusCell.self, forCellWithReuseIdentifier: EmojiPaletteStatusCell.reuseIdentifier)
        collectionView.register(EmojiPaletteHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: EmojiPaletteHeader.reuseIdentifier)
        addSubview(collectionView)
        // 絵文字のリストを検索欄の裏まで伸ばし、下の段と同じく、重なった端をシステムにぼかさせる。
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
        // 絵文字のリストを下の段の裏まで伸ばし、重なった端をシステムにぼかさせる。iOS 26のバーの下をタイムラインが流れるときと同じ見え方にするため。
        let edgeInteraction = UIScrollEdgeElementContainerInteraction()
        edgeInteraction.scrollView = collectionView
        edgeInteraction.edge = .bottom
        bottomBar.addInteraction(edgeInteraction)
        addSubview(bottomBar)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.configuration?.image = UIImage(systemName: "delete.backward")
        deleteButton.configuration?.baseForegroundColor = .label
        deleteButton.accessibilityLabel = EmojiPaletteTexts.delete
        deleteButton.addAction(UIAction { [weak self] _ in
            self?.playInputFeedback()
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
        // 検索欄と下の段の間。絵文字のリストの中身が見える場所で、空や見つからないことの文言をこの真ん中に置く。
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
            searchField.trailingAnchor.constraint(equalTo: skinToneButton.leadingAnchor, constant: -8),
            skinToneButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            skinToneButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            skinToneButton.widthAnchor.constraint(equalToConstant: Self.searchRowHeight),
            skinToneButton.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),
            searchField.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            // 絵文字のリストと下の段の間は空けない。空けると、どちらにも当たらずに押しても反応しない帯ができる。
            // 絵文字のリストは下の段の裏まで伸ばす。下の段の分の余白を足し、いちばん下の絵文字も下の段より上まで送れるようにする。
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
            // 幅に入るだけの列に、左から右、上から下へ詰める。横長のカスタム絵文字は、縦横比に合わせてマスを横に足す。
            let columns = max(1, Int((environment.container.effectiveContentSize.width - 16) / size))
            let placements = EmojiPaletteGrid.place(spans: self?.spans(inSection: index) ?? [], columns: columns)
            let rows = max((placements.last?.row ?? 0) + 1, 1)
            let group = NSCollectionLayoutGroup.custom(
                layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(size * CGFloat(columns)), heightDimension: .absolute(size * CGFloat(rows)))
            ) { _ in
                placements.map { placement in
                    NSCollectionLayoutGroupCustomItem(frame: CGRect(x: CGFloat(placement.column) * size, y: CGFloat(placement.row) * size, width: CGFloat(placement.span) * size, height: size))
                }
            }
            let section = NSCollectionLayoutSection(group: group)
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
            self?.configureCell(at: indexPath, cell)
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: EmojiPaletteHeader.reuseIdentifier, for: indexPath)
            if let self, let header = header as? EmojiPaletteHeader, sections.indices.contains(indexPath.section) {
                header.label.text = sections[indexPath.section].kind.title
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
                let key = switch customStatus { case .failed(let reason): "failed:\(FailureText.withoutLogIn(reason))"; case .loading, nil: "loading" }
                snapshot.appendItems([Item(section: section.kind, key: key)], toSection: section.kind)
                continue
            }
            snapshot.appendItems(section.emojis.map { Item(section: section.kind, key: $0.recentKey) }, toSection: section.kind)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// まとまりの絵文字ごとに、横に使うマスの数。Unicodeの絵文字と、縦横比の分からないカスタム絵文字は1マス。
    private func spans(inSection index: Int) -> [Int] {
        guard sections.indices.contains(index) else { return [] }
        return sections[index].emojis.map { emoji in
            guard case .custom(let custom) = emoji else { return 1 }
            return EmojiPaletteGrid.span(aspectRatio: custom.aspectRatio, maxSpan: maxSpan, minimumHeightFraction: minimumHeightFraction)
        }
    }

    private func emoji(at indexPath: IndexPath) -> PaletteEmoji? {
        guard sections.indices.contains(indexPath.section), sections[indexPath.section].emojis.indices.contains(indexPath.item) else { return nil }
        return sections[indexPath.section].emojis[indexPath.item]
    }

    /// すべての絵文字を描き直す。枠の大きさやUnicodeの絵文字の絵のように、組み立てたセルすべてに関わる設定を変えたときに使う。
    /// 個人セットのまとまりの絵文字。
    private static func personalEmojis(in sections: [EmojiPaletteSection]) -> [Item: PaletteEmoji] {
        var emojis: [Item: PaletteEmoji] = [:]
        for section in sections {
            guard case .personal = section.kind else { continue }
            for emoji in section.emojis {
                emojis[Item(section: section.kind, key: emoji.recentKey)] = emoji
            }
        }
        return emojis
    }

    /// 個人セットは出している間に並べ直すので、同じ場所の絵文字の画像だけが変わることがある。項目はショートコードで見分けていて、
    /// 並べ直しではそのセルを描き直さないので、ここで描き直す。
    private func reconfigureChangedPersonalEmojis(since previous: [Item: PaletteEmoji]) {
        guard !previous.isEmpty else { return }
        let changed = Self.personalEmojis(in: sections).filter { item, emoji in previous[item].map { $0 != emoji } ?? false }.map(\.key)
        guard !changed.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureAllCells() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        updateSectionIcons(matching: nil)
    }

    /// 届いた画像の絵文字のうち、見えているセルだけを描き直す。
    /// 画面に入る前に組み立てたセルは、画面に入るときに描き直す（`willDisplay`）。組み立てたあとに画像が届いたセルを、空のまま画面に入れないため。
    /// 差分（`reconfigureItems`）では描き直さない。差分の計算は絵文字の数（数千個のサーバーがある）に比例し、スクロール中は画像が1秒に数十回届くため。
    private func reconfigureVisibleCells(showing urls: Set<URL>) {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard case .custom(let custom)? = emoji(at: indexPath), custom.hasImage(in: urls) else { continue }
            configureCell(at: indexPath, collectionView.cellForItem(at: indexPath))
        }
        updateSectionIcons(matching: urls)
    }

    private func configureCell(at indexPath: IndexPath, _ cell: UICollectionViewCell?) {
        guard let cell = cell as? EmojiPaletteCell, let emoji = emoji(at: indexPath) else { return }
        #if DEBUG
        let start = AppDependencies.mediaTime()
        defer { (collectionView as? EmojiPaletteCollectionView)?.debugConfigureDurations?.append(AppDependencies.mediaTime() - start) }
        #endif
        FrameWork.measure("EmojiPaletteCell.configure") { cell.configure(emoji, store: emojiImages, requester: self, thumbnails: thumbnails, glyphs: glyphImages, glyphArchive: glyphArchive, emojiStyle: emojiStyle) }
    }

    /// できたUnicodeの絵文字の画像を、それを待っているセルに入れる。
    private func glyphDidLoad(_ request: EmojiGlyphImageStore.Request, _ image: UIImage) {
        for case let cell as EmojiPaletteCell in collectionView.visibleCells {
            cell.showGlyph(image, for: request)
        }
    }

    // MARK: - まとまりのボタン

    /// まとまりのボタン。最近使ったものは時計、検索の結果は虫めがね、カテゴリーはその先頭の絵文字の画像をアイコンにする。
    /// 名前の文字にすると、絵文字のリストの端の効果（`.soft`）でぼけた絵文字の上に重なって読みにくかった。iOSの絵文字キーボードの下の段もアイコンで並べる。
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
            button.accessibilityLabel = section.kind.title
            button.showsLargeContentViewer = true
            button.largeContentTitle = section.kind.title
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
        case .personal:
            // 個人セットのカテゴリーは、Fedibirdで選んだ見出し（絵文字か、名前の先頭の1文字）をアイコンにする。
            switch section.heading {
            // scialint:disable:next fixed_font_size
            case .text(let text): return Self.icon(from: text, font: .systemFont(ofSize: Self.sectionIconSize * 0.8, weight: .medium)).withRenderingMode(.alwaysTemplate)
            // scialint:disable:next fixed_font_size
            case .emoji(.standard(let emoji)): return Self.icon(from: emoji.emoji, font: EmojiFont.font(.systemFont(ofSize: Self.sectionIconSize * 0.8), style: emojiStyle), color: UIColor.label.resolvedColor(with: traitCollection))
            case .emoji(.custom), nil: break
            }
            fallthrough
        case .uncategorized, .category:
            // 画像が届く前は空けておき、届いたら`updateSectionIcons`で入れる。
            // セルと同じ画像を読む。
            guard case .custom(let emoji) = Self.iconEmoji(of: section), let image = emojiImages.image(for: EmojiPaletteCell.choice(of: emojiImages).url(of: emoji)) else { return nil }
            return Self.icon(from: image)
        case .standard(let title):
            // Unicodeの絵文字のまとまりは、iOSの絵文字キーボードと同じく、記号のアイコンにする。時計や虫めがねと同じ色で並ぶ。
            return UIImage(systemName: StandardEmojiGroup.symbolName(forTitle: title) ?? "square.grid.2x2")
        }
    }

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

    /// アイコンにする絵文字。個人セットのカテゴリーは見出しの絵文字、ほかは先頭の絵文字。
    private static func iconEmoji(of section: EmojiPaletteSection) -> PaletteEmoji? {
        if case .emoji(let emoji) = section.heading { return emoji }
        return section.emojis.first
    }

    /// 文字を、アイコンの大きさの枠の中央に描く。まとまりのボタンは、文字の大きさの設定によらず決まった大きさのアイコンを並べるので、
    /// `font`はその枠に合わせた大きさで渡す。
    /// - Parameter color: 絵文字の絵がなく文字で描かれる絵文字（Twemojiでの「©」など）の色。
    private static func icon(from string: String, font: UIFont, color: UIColor = .label) -> UIImage {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: sectionIconSize, height: sectionIconSize))
        return renderer.image { _ in
            text.draw(at: CGPoint(x: (sectionIconSize - size.width) / 2, y: (sectionIconSize - size.height) / 2))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// アイコンの画像が届いたまとまりのボタンに、アイコンを入れる。
    private func updateSectionIcons(matching urls: Set<URL>?) {
        for (index, button) in sectionButtons.enumerated() where sections.indices.contains(index) {
            let section = sections[index]
            // Unicodeの絵文字の見出しは、外観が変わったときに、文字で描かれる絵文字の色を合わせ直す。
            if urls == nil, case .emoji(.standard) = section.heading {
                button.configuration?.image = sectionIcon(for: section)
                button.largeContentImage = button.configuration?.image
                continue
            }
            guard case .custom(let first) = Self.iconEmoji(of: section), section.kind != .recent, section.kind != .searchResults else { continue }
            if let urls, !first.hasImage(in: urls) { continue }
            button.configuration?.image = sectionIcon(for: section)
            button.largeContentImage = button.configuration?.image
        }
    }

    private func scrollToTop() {
        // コードから位置を動かすと、慣性で動いている途中のスクロールは止まりの通知を受けずに終わる。
        recordScroll()
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    /// まとまりの見出しが絵文字のリストの上端に来るまでスクロールする。下の端を越える分は、いちばん下までにする。
    private func scrollToSection(_ index: Int) {
        guard sections.indices.contains(index), !sections[index].emojis.isEmpty || sections[index].kind == .customEmojiStatus else { return }
        UIDevice.current.playInputClick()
        collectionView.layoutIfNeeded()
        let header = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: index))
        let top = -collectionView.adjustedContentInset.top
        let bottom = max(top, collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
        let y = min(max((header?.frame.minY ?? 0) + top, top), bottom)
        recordScroll()
        let start = collectionView.contentOffset.y
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        // 移る間の落ちたフレームも、指のスクロールと同じく数える。動かないときは、終わりの通知が来ない。
        if y != start {
            scrollStart = (start, mediaTime(), Self.sectionJumpScreenName)
            scrollHitches.start()
        }
        setSelectedSection(index)
    }

    #if DEBUG
    /// まとまりのボタンを押したのと同じく、`index`番目（負なら後ろから）のまとまりへ移り、移り終えたら落ちたフレームを渡す。動かなければすぐ空の結果を渡す。
    /// 並べ直し1回ごとの時間も、落ちなかったフレームの分まで渡す。
    func debugJump(toSection index: Int, completion: @escaping (HitchCounter.Summary, FrameWorkTally, (layouts: [Double], configures: [Double])) -> Void) {
        let resolved = index < 0 ? sections.count + index : index
        // 前の移動の途中なら、その結果を渡さないよう先に終える。
        recordScroll()
        (collectionView as? EmojiPaletteCollectionView)?.debugLayoutDurations = []
        (collectionView as? EmojiPaletteCollectionView)?.debugConfigureDurations = []
        debugJumpCompletion = completion
        scrollToSection(resolved)
        guard scrollStart == nil, let completion = debugJumpCompletion else { return }
        debugJumpCompletion = nil
        (collectionView as? EmojiPaletteCollectionView)?.debugLayoutDurations = nil
        (collectionView as? EmojiPaletteCollectionView)?.debugConfigureDurations = nil
        completion(scrollHitches.finish().summary, FrameWorkTally(), ([], []))
    }
    #endif

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
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        configureCell(at: indexPath, cell)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let emoji = emoji(at: indexPath) else { return }
        playInputFeedback()
        onSelect(emoji)
    }

    /// カスタム絵文字は、長押しで大きく見せてメニューを出す。Unicodeの絵文字では出さない。決まりはdocs/menus.mdの「カスタム絵文字のメニュー」にある。
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, indexPaths.count == 1 else { return nil }
        if case .standard(let standard) = emoji(at: indexPath) {
            return skinToneMenuConfiguration(for: standard)
        }
        guard case .custom(let emoji) = emoji(at: indexPath) else { return nil }
        let store = emojiImages
        let height = previewHeight
        // 横長の絵文字も、パレットの幅に収める。
        let maxWidth = bounds.width - 64
        let menu = menu
        return UIContextMenuConfiguration(identifier: nil, previewProvider: { [weak self] in
            guard let self else { return nil }
            let preview = EmojiPalettePreviewController(emoji: emoji, store: store, requester: self, height: height, maxWidth: maxWidth)
            self.preview = preview
            return preview
        }, actionProvider: { _ in
            menu?(emoji)
        })
    }

    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        pairSelection = nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, scrollView.isTracking || scrollView.isDecelerating else { return }
        FrameWork.measure("EmojiPaletteView.scrollViewDidScroll") { updateSelectedSection() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        // 慣性で動いている途中で触れると、前のスクロールは止まりの通知を受けずに終わるため、ここで記録する。
        recordScroll()
        scrollStart = (scrollView.contentOffset.y, mediaTime(), Self.scrollScreenName)
        scrollHitches.start()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === collectionView, !decelerate else { return }
        recordScroll()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        recordScroll()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        recordScroll()
    }

    private func recordScroll() {
        guard let start = scrollStart else { return }
        scrollStart = nil
        let (hitches, work) = scrollHitches.finish()
        #if DEBUG
        if let completion = debugJumpCompletion {
            debugJumpCompletion = nil
            let list = collectionView as? EmojiPaletteCollectionView
            let durations = (layouts: list?.debugLayoutDurations ?? [], configures: list?.debugConfigureDurations ?? [])
            list?.debugLayoutDurations = nil
            list?.debugConfigureDurations = nil
            completion(hitches, work, durations)
        }
        #endif
        FrameWorkLog.record(work, screen: start.screen)
        UserAction.scroll(ScrollRecord(
            screen: start.screen,
            startOffset: start.offset,
            endOffset: collectionView.contentOffset.y,
            viewportHeight: collectionView.bounds.inset(by: collectionView.adjustedContentInset).height,
            duration: mediaTime() - start.time,
            hitches: hitches
        )).record()
    }

    /// スクロールの記録に書く画面の名前。
    static let scrollScreenName = "emojiPalette"
    /// まとまりのボタンで移ったときの、スクロールの記録に書く画面の名前。指のスクロールと分けて読めるようにする。
    static let sectionJumpScreenName = "emojiPaletteSectionJump"
}

// MARK: - 肌の色

/// 肌の色の選び方。決まりはdocs/compose.mdの「絵文字の肌の色」にある。
extension EmojiPaletteView {
    /// メニューと検索欄の隣のボタンに置く、絵文字の絵。メニューに文字色で塗られないよう、元の色のまま置く。
    private func glyphIcon(_ text: String, side: CGFloat) -> UIImage {
        EmojiGlyphImageStore.drawNow(EmojiGlyphImageStore.Request(
            text: text, pointSize: side * 0.8, style: emojiStyle, width: side, height: side,
            scale: traitCollection.displayScale, userInterfaceStyle: traitCollection.userInterfaceStyle
        )).withRenderingMode(.alwaysOriginal)
    }

    /// 既定の肌の色のボタン。今の既定の色の手の絵文字を出し、押すと6色から選ぶ。
    fileprivate func updateSkinToneButton() {
        let hand = StandardEmoji(emoji: "✋", name: "", keywords: [], version: "", skinTones: .single(["✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"]))
        skinToneButton.configuration?.image = glyphIcon(hand.withSkinTone(defaultSkinTone).emoji, side: 24)
        skinToneButton.accessibilityValue = defaultSkinTone.title
        skinToneButton.menu = Self.paletteMenu(EmojiSkinTone.allCases.map { tone in
            UIAction(title: tone.title, image: glyphIcon(hand.withSkinTone(tone).emoji, side: 28), state: tone == defaultSkinTone ? .on : .off) { [weak self] _ in
                self?.onDefaultSkinToneChange(tone)
            }
        })
    }

    /// 肌の色を変えられる絵文字の長押し。絵を持ち上げ、下に肌の色を並べる。変えられない絵文字では出さない。
    fileprivate func skinToneMenuConfiguration(for emoji: StandardEmoji) -> UIContextMenuConfiguration? {
        guard let skinTones = emoji.skinTones else { return nil }
        let current = emoji.currentSkinTones
        if skinTones.isPair {
            pairSelection = (emoji, current.first, current.second)
        }
        let style = emojiStyle
        let side = previewHeight
        return UIContextMenuConfiguration(identifier: nil, previewProvider: { [weak self] in
            let preview = EmojiGlyphPreviewController(text: emoji.emoji, style: style, side: side)
            self?.glyphPreview = preview
            return preview
        }, actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return skinTones.isPair ? pairSkinToneMenu() : singleSkinToneMenu(for: emoji, current: current.first)
        })
    }

    /// 1人の絵文字。押した色の絵文字を、その1回だけ入れる。既定の色は変えない。
    private func singleSkinToneMenu(for emoji: StandardEmoji, current: EmojiSkinTone) -> UIMenu {
        Self.paletteMenu(EmojiSkinTone.allCases.map { tone in
            let toned = emoji.withSkinTone(tone)
            return UIAction(title: tone.title, image: glyphIcon(toned.emoji, side: 28), state: tone == current ? .on : .off) { [weak self] _ in
                self?.insert(toned)
            }
        })
    }

    /// 2人の絵文字。2人それぞれの色を選んでから、入れる。色を押してもメニューは閉じず、持ち上げた絵を選んだ色に描き直す。
    private func pairSkinToneMenu() -> UIMenu? {
        guard let selection = pairSelection else { return nil }
        func row(_ title: String, current: EmojiSkinTone, choose: @escaping (EmojiSkinTone) -> Void) -> UIMenu {
            UIMenu(title: title, options: [.displayInline, .displayAsPalette], children: EmojiSkinTone.allCases.map { tone in
                UIAction(title: tone.title, image: glyphIcon(Self.swatch(tone), side: 28), attributes: .keepsMenuPresented, state: tone == current ? .on : .off) { _ in choose(tone) }
            })
        }
        let toned = selection.emoji.withSkinTones(selection.first, selection.second)
        return UIMenu(children: [
            row(EmojiPaletteTexts.firstPersonSkinTone, current: selection.first) { [weak self] tone in self?.choosePairTone(first: tone) },
            row(EmojiPaletteTexts.secondPersonSkinTone, current: selection.second) { [weak self] tone in self?.choosePairTone(second: tone) },
            UIAction(title: EmojiPaletteTexts.insertEmoji, image: glyphIcon(toned.emoji, side: 28)) { [weak self] _ in self?.insert(toned) },
        ])
    }

    /// 片方だけに肌の色を付けた並びはUnicodeにないので、片方を外したら2人とも外し、外れている相手には同じ色を付ける。
    private func choosePairTone(first: EmojiSkinTone? = nil, second: EmojiSkinTone? = nil) {
        guard var selection = pairSelection else { return }
        let chosen = first ?? second ?? .none
        if chosen == .none {
            selection.first = .none
            selection.second = .none
        } else {
            selection.first = first ?? (selection.first == .none ? chosen : selection.first)
            selection.second = second ?? (selection.second == .none ? chosen : selection.second)
        }
        pairSelection = selection
        glyphPreview?.text = selection.emoji.withSkinTones(selection.first, selection.second).emoji
        collectionView.contextMenuInteraction?.updateVisibleMenu { [weak self] menu in self?.pairSkinToneMenu() ?? menu }
    }

    /// 色を横に並べるだけのメニュー。並べる段はルートに置かず、ルートの中に入れる。
    /// Macでは、ルートを`.displayAsPalette`にしたメニューは表示されずに終わり、UIKitがそのメニューを閉じ終えていない扱いのまま残すため、
    /// アプリを終えるまでどのメニューも出なくなる。
    private static func paletteMenu(_ children: [UIMenuElement]) -> UIMenu {
        UIMenu(children: [UIMenu(options: [.displayInline, .displayAsPalette], children: children)])
    }

    /// 肌の色の見本。肌の色の修飾だけを描くと、その色の四角になる。色なしは、絵文字の書体の既定の色に近い手で示す。
    private static func swatch(_ tone: EmojiSkinTone) -> String {
        switch tone {
        case .none: "✋"
        case .light: "✋🏻"
        case .mediumLight: "✋🏼"
        case .medium: "✋🏽"
        case .mediumDark: "✋🏾"
        case .dark: "✋🏿"
        }
    }

    private func insert(_ emoji: StandardEmoji) {
        playInputFeedback()
        onSelect(.standard(emoji))
    }

    /// 絵文字を入れたときと削除キーを押したときに、入力音を鳴らして触覚を返す。決まりはdocs/compose.mdの「入れ方」にある。
    private func playInputFeedback() {
        UIDevice.current.playInputClick()
        let intensity = AppDependencies.tuning.value(of: TuningCatalog.composeEmojiPaletteHapticIntensity)
        guard intensity > 0 else { return }
        UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred(intensity: intensity)
    }
}

/// パレットで長押ししたUnicodeの絵文字を、大きく見せる。
final class EmojiGlyphPreviewController: UIViewController {
    var text: String {
        didSet { draw() }
    }

    private let style: EmojiStyle
    private let side: CGFloat
    private let imageView = UIImageView()
    private static let padding: CGFloat = 16

    init(text: String, style: EmojiStyle, side: CGFloat) {
        self.text = text
        self.style = style
        self.side = side
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: side + Self.padding * 2, height: side + Self.padding * 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .center
        view.addSubview(imageView)
        draw()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        imageView.frame = view.bounds
    }

    private func draw() {
        guard isViewLoaded else { return }
        imageView.image = EmojiGlyphImageStore.drawNow(EmojiGlyphImageStore.Request(
            text: text, pointSize: side * 0.8, style: style, width: side, height: side,
            scale: traitCollection.displayScale, userInterfaceStyle: traitCollection.userInterfaceStyle
        ))
    }
}

/// パレットで長押ししたカスタム絵文字を、大きく見せる。パレットと同じく、設定によらず動かす。
final class EmojiPalettePreviewController: UIViewController {
    private let emoji: ServerEmoji
    private let store: EmojiImageStore<UIImage>
    /// 大きく読み直し終えたことを知らせてもらう、ストアの知らせ先の持ち主。パレットが受けて、このプレビューに渡す（`imagesDidLoad`）。
    private weak var requester: AnyObject?
    private let height: CGFloat
    private let maxWidth: CGFloat
    private let imageView = EmojiImageView(frame: .zero)
    private static let padding: CGFloat = 16

    init(emoji: ServerEmoji, store: EmojiImageStore<UIImage>, requester: AnyObject, height: CGFloat, maxWidth: CGFloat) {
        self.emoji = emoji
        self.store = store
        self.requester = requester
        self.height = height
        self.maxWidth = maxWidth
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        view.addSubview(imageView)
        // 使う人が長押しして開いたので、前に読めなかった画像も間隔を待たずに読み直す。
        loadImages(retriesNow: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        imageView.frame = view.bounds.insetBy(dx: Self.padding, dy: Self.padding)
    }

    func imagesDidLoad(_ urls: Set<URL>) {
        guard urls.contains(emoji.url) || urls.contains(emoji.staticUrl) else { return }
        loadImages(retriesNow: false)
    }

    /// 持っている画像で描き、描く高さに足りなければ読み直させる。届いたら`imagesDidLoad`で描き直す。
    private func loadImages(retriesNow: Bool) {
        let choice = EmojiPaletteCell.choice(of: store)
        let url = choice.url(of: emoji)
        // 縦横比は、持っている画像から知る。まだなければサーバーが返したものを使い、どちらもなければ正方形にする。
        let known = store.image(for: url, retriesNow: retriesNow, requester: requester)
        let aspectRatio: CGFloat = if let size = known?.size, size.height > 0 {
            size.width / size.height
        } else {
            emoji.aspectRatio.map { CGFloat($0) } ?? 1
        }
        let size = Self.contentSize(aspectRatio: aspectRatio, height: height, maxWidth: maxWidth)
        // 横長の絵文字は幅に収めて縮めるので、縮めたあとの高さで読む。縮める前の高さで読むと、描く大きさの何倍もの画素を展開する。
        let pixelHeight = RichTextRenderer.pixelHeight(of: size.height - Self.padding * 2, scale: traitCollection.displayScale)
        imageView.stillImage = store.image(for: url, pixelHeight: pixelHeight, retriesNow: retriesNow, requester: requester)
        imageView.animation = choice.animationURL(of: emoji).flatMap { store.animation(for: $0, pixelHeight: pixelHeight, requester: requester) }
        preferredContentSize = size
    }

    /// 絵を`height`の高さで描く大きさ。幅が`maxWidth`を超える横長の絵文字は、幅を`maxWidth`にして高さを縮める。
    static func contentSize(aspectRatio: CGFloat, height: CGFloat, maxWidth: CGFloat) -> CGSize {
        let width = height * aspectRatio
        let scale = min(1, max(1, maxWidth - padding * 2) / max(1, width))
        return CGSize(width: (width * scale).rounded() + padding * 2, height: (height * scale).rounded() + padding * 2)
    }
}

/// 並べ直しにかかった時間を、スクロールの記録に渡す。
private final class EmojiPaletteCollectionView: UICollectionView {
    #if DEBUG
    /// `scia-debug://emoji-palette/section`で移る間の、並べ直し1回ごとの時間（秒）。落ちなかったフレームも含めて、1フレームの重さを読むため。
    var debugLayoutDurations: [Double]?
    /// 同じ間の、セルの組み立て1回ごとの時間（秒）。
    var debugConfigureDurations: [Double]?
    #endif

    override func layoutSubviews() {
        #if DEBUG
        let start = AppDependencies.mediaTime()
        defer { debugLayoutDurations?.append(AppDependencies.mediaTime() - start) }
        #endif
        FrameWork.measure("EmojiPaletteCollectionView.layoutSubviews") { super.layoutSubviews() }
    }
}

/// パレットの絵文字1つ。押している間は、システムの絵文字キーボードのように背景を付ける。
final class EmojiPaletteCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiPaletteCell"
    private let imageView = EmojiImageView(frame: .zero)
    /// Unicodeの絵文字を、文字として描いた画像で出す。
    private let glyphView = UIImageView()
    /// 画像ができるのを待っているUnicodeの絵文字。
    private var glyphRequest: EmojiGlyphImageStore.Request?
    private let highlight = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.backgroundColor = .tertiarySystemFill
        highlight.layer.cornerRadius = 8
        highlight.layer.cornerCurve = .continuous
        highlight.isHidden = true
        contentView.addSubview(highlight)
        contentView.addSubview(imageView)
        glyphView.contentMode = .center
        // 端末に置いた、形だけのUnicodeの絵文字の画像に付ける色。
        glyphView.tintColor = .label
        contentView.addSubview(glyphView)
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
        let inset = Self.imageInset(in: contentView.bounds.size)
        imageView.frame = contentView.bounds.insetBy(dx: inset, dy: inset)
        glyphView.frame = imageView.frame
    }

    override var isHighlighted: Bool {
        didSet { highlight.isHidden = !isHighlighted }
    }

    /// 横長の絵文字はマスを横に足して幅が変わるので、余白は高さから決める。
    private static func imageInset(in size: CGSize) -> CGFloat {
        round(size.height * EmojiPaletteGrid.imageInsetFraction)
    }

    /// 絵を描く枠の高さ。
    private static func imageSide(in size: CGSize) -> CGFloat {
        size.height - imageInset(in: size) * 2
    }

    /// パレットが読む画像。設定によらず動かすので、元の画像を読む。
    /// 端末の設定が動く画像を許さないときも元の画像を読み、`EmojiImageView`が動かさずに描く。開いている間に端末の設定が変わったら、読み直さずに動かせる。
    static func choice(of store: EmojiImageStore<UIImage>) -> EmojiImageChoice {
        store.choice(animates: true)
    }

    /// カスタム絵文字は、「カスタム絵文字のアニメーションを再生する」の設定によらず動かす。
    /// 静止画がメモリになければ、届くまで小さい静止画で描き、届いたら差し替える（`reconfigureVisibleCells`）。
    /// - Parameter requester: 大きく読み直し終えたことを知らせてもらう、ストアの知らせ先の持ち主（パレット）。
    func configure(_ emoji: PaletteEmoji, store: EmojiImageStore<UIImage>, requester: AnyObject, thumbnails: EmojiThumbnails, glyphs: EmojiGlyphImageStore, glyphArchive: EmojiGlyphArchive, emojiStyle: EmojiStyle) {
        switch emoji {
        case .custom(let custom):
            glyphView.isHidden = true
            glyphView.image = nil
            glyphRequest = nil
            imageView.isHidden = false
            // 枠を大きくしたときは、描く高さで読む。既定の枠（48pt）は既定の高さの1.1倍以内なので、読み直さない。
            let pixelHeight = RichTextRenderer.pixelHeight(of: Self.imageSide(in: bounds.size), scale: traitCollection.displayScale)
            // 動かすので元の画像だけを読み、動かない絵文字もその最初のコマで描く。
            let choice = Self.choice(of: store)
            let url = choice.url(of: custom)
            imageView.stillImage = store.image(for: url, pixelHeight: pixelHeight, requester: requester) ?? thumbnails.image(for: url).map { UIImage(cgImage: $0) }
            imageView.animation = choice.animationURL(of: custom).flatMap { store.animation(for: $0, pixelHeight: pixelHeight, requester: requester) }
            accessibilityLabel = custom.shortcode
            accessibilityValue = nil
        case .standard(let standard):
            imageView.isHidden = true
            imageView.stillImage = nil
            imageView.animation = nil
            glyphView.isHidden = false
            // 名前は肌の色を付けても同じなので、色違いを読み上げで区別できるよう、肌の色を値に置く。
            accessibilityLabel = standard.name
            accessibilityValue = standard.skinToneDescription
            let geometry = Self.glyphGeometry(cellSize: bounds.size, scale: traitCollection.displayScale, style: emojiStyle)
            let request = EmojiGlyphImageStore.Request(
                text: standard.emoji,
                pointSize: geometry.pointSize,
                style: geometry.style,
                width: geometry.width,
                height: geometry.height,
                scale: geometry.scale,
                userInterfaceStyle: traitCollection.userInterfaceStyle
            )
            guard request != glyphRequest || glyphView.image == nil else { break }
            glyphRequest = request
            glyphView.image = Self.glyphImage(for: request, glyphs: glyphs, archive: glyphArchive)
        }
    }

    /// `cellSize`のマスに、Unicodeの絵文字を描く大きさ。
    static func glyphGeometry(cellSize: CGSize, scale: CGFloat, style: EmojiStyle) -> EmojiGlyphArchive.Geometry {
        EmojiGlyphArchive.Geometry(
            // 絵文字の文字の大きさは、枠いっぱいの画像と同じくらいに見えるよう、枠の高さの少し下にする。
            // 文字ではなく、カスタム絵文字の画像と並べる絵として描くため、端末の文字の大きさではなく枠の大きさで決める。
            pointSize: max(cellSize.height, 32) * 0.58,
            width: cellSize.width - imageInset(in: cellSize) * 2,
            height: imageSide(in: cellSize),
            scale: scale,
            style: style,
            systemVersion: EmojiGlyphArchive.systemVersion
        )
    }

    /// Unicodeの絵文字の画像。端末に置いた描く大きさの画像があればそれを、なければメモリの画像を使い、どちらもなければ、
    /// メモリの画像を作らせて、届くまで端末に置いた小さい画像で描く（docs/animated-custom-emoji.mdの「Unicodeの絵文字の画像」）。
    /// 端末に置いた画像のうち形だけのものは、テンプレートの画像にして、今の外観の文字の色（`glyphView`の`tintColor`）で描く。
    private static func glyphImage(for request: EmojiGlyphImageStore.Request, glyphs: EmojiGlyphImageStore, archive: EmojiGlyphArchive) -> UIImage? {
        let geometry = EmojiGlyphArchive.Geometry(
            pointSize: request.pointSize, width: request.width, height: request.height, scale: request.scale, style: request.style, systemVersion: EmojiGlyphArchive.systemVersion
        )
        archive.use(geometry)
        let stored = archive.glyph(for: request.text, geometry: geometry)
        func image(_ glyph: EmojiGlyphArchive.Glyph) -> UIImage {
            // 小さい画像も、描く大きさの画像と同じポイントの大きさで描く。
            let image = UIImage(cgImage: glyph.image, scale: CGFloat(glyph.image.height) / request.height, orientation: .up)
            return glyph.isShape ? image.withRenderingMode(.alwaysTemplate) : image
        }
        if let stored, stored.isFull {
            return image(stored)
        }
        return glyphs.image(for: request) ?? stored.map(image)
    }

    func showGlyph(_ image: UIImage, for request: EmojiGlyphImageStore.Request) {
        guard request == glyphRequest else { return }
        glyphView.image = image
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

/// カスタム絵文字のリストを読んでいる間か、読めなかったときに、カスタム絵文字の場所に置く段。読めなかったときは、文言の下に、押すと読み直すボタンを添える。
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
        retryButton.configuration?.title = EmojiPaletteTexts.retry
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry() }, for: .primaryActionTriggered)
        // 読み込み中はインジケーターと文言を横に、失敗は文言の下に読み直すボタンを置く。カスタム絵文字の中身の代わりに出すので、タイムラインが空のときやタイムラインの失敗と同じく中央にそろえる。
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
            label.text = EmojiPaletteTexts.loadingCustomEmojis
            retryButton.isHidden = true
        case .failed(let reason):
            spinner.stopAnimating()
            spinner.isHidden = true
            // カスタム絵文字のリスト（`api/v1/custom_emojis`）はログインなしで読めるので、401にはならない。
            label.text = FailureText.withoutLogIn(reason)
            retryButton.isHidden = false
        }
    }
}
