import SciaCore
import UIKit

/// プロフィールの一覧の頭に置く、アカウントの情報と、一覧の切り替え。
final class ProfileHeaderView: UIView {
    struct Content {
        let account: Account
        let followState: FollowState
        let followedBy: Bool
        let isChangingFollow: Bool
        /// 読めなかったフォローの関係を読み直している途中。
        let isReloadingRelationship: Bool
        /// フォローの関係を待つのが長引いている。関係を読む前のボタンの中に、アクティビティインジケータを出す。
        let showsRelationshipActivity: Bool
        let tab: ProfileTab
        let postsFilter: ProfilePostsFilter
        let avatarShape: AvatarShape
        let animatesAvatar: Bool
        /// 名前、自己紹介、補足情報のアニメーションするカスタム絵文字を動かす。
        let animatesCustomEmojis: Bool
        /// 名前や自己紹介に付ける言語。言語が分からないため、設定から決める。
        let glyphLanguage: String
        /// 自分のサーバーのアカウントではない。投稿や数が実際と合わないことを知らせる。
        let isRemote: Bool
    }

    var onToggleFollow: ((UIView) -> Void)?
    /// 自分のプロフィールで、フォローのボタンの場所に出す「プロフィールを編集」を押した。
    var onEditProfile: (() -> Void)?
    /// フォローかフォロワーの数が押されたときに、どちらの一覧かを渡して呼ぶ。
    var onOpenCountList: ((ProfileCountList) -> Void)?
    /// フォローの関係を読めなかったときに、フォローのボタンの場所に出す再試行が押された。
    var onRetryRelationship: (() -> Void)?
    var onSelectTab: ((ProfileTab) -> Void)?
    var onChangePostsFilter: ((ProfilePostsFilter) -> Void)?
    var onOpenOriginal: (() -> Void)?
    /// アイコンかヘッダー画像がタップされた。画像を読み込み終えていなければ呼ばない。
    var onOpenImage: ((ProfileImage) -> Void)?
    /// アイコンかヘッダー画像を長押ししたときの、メディアのメニュー。画像を読み込み終えていなければ呼ばない。nilを返せばメニューを出さない。
    /// 並びがnilなら設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    var menuForImage: ((ProfileImage, MenuLayout<MediaMenuItem>.Groups?) -> UIMenu?)?
    /// アイコンとヘッダー画像の、メディアのメニューの長押し。決まりはdocs/menus.mdの「メディアのメニュー」にある。
    private var imageMenuInteractions: [ProfileImage: MediaMenuInteraction] = [:]
    /// 表示名、自己紹介、補足情報の行を長押ししたときの、文章のメニュー。nilを返せばメニューを出さない。
    var menuForText: ((ProfileTextPart) -> UIMenu?)?
    /// 文章のメニューを出したときと閉じたとき。
    var textMenuLifecycle = MenuLifecycle()
    /// 表示名と自己紹介の、文章のメニューの長押し。決まりはdocs/menus.mdの「プロフィールの文章のメニュー」にある。
    private var textMenuInteractions: [ProfileTextMenuInteraction] = []
    /// 補足情報の行の、文章のメニューの長押し。行を作り直すたびに付け直す。
    private var fieldMenuInteractions: [ProfileTextMenuInteraction] = []
    /// 関係が届いて、フォローのボタンの場所取りから本物の文字に変わるときのフェードの時間。0なら切り替える。
    var followRevealDuration: TimeInterval = 0
    /// 自己紹介か補足情報の値のリンクがタップされたときと、メンションの長押しのメニューでプロフィールを選んだときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// 固定された投稿のカードが押されたときに、その投稿と、ウインドウの座標でのカードの枠を渡して呼ぶ。
    var onOpenPinned: ((Status, CGRect) -> Void)? {
        get { pinnedShelf.onOpen }
        set { pinnedShelf.onOpen = newValue }
    }
    /// 「さらに表示」で自己紹介を広げたときに、下の内容を下げていく時間を渡して呼ぶ。0なら動かさずに切り替える。
    var onExpandNote: ((TimeInterval) -> Void)?
    /// 「さらに表示」で自己紹介を広げるときに、下の内容を下げていく時間。0なら切り替える。
    var noteExpandDuration: TimeInterval = 0
    /// ヘッダー画像を読み込み終えて、バーの下へ伸ばすかが変わったときに呼ぶ。
    var onChangeExtendsUnderBars: (() -> Void)?
    /// ヘッダー画像の大きさや位置が変わって、ヘッダーの高さが変わったときに呼ぶ。
    var onChangeBannerLayout: (() -> Void)?
    /// ステータスバーとナビゲーションバーの高さ。ヘッダー画像を、ナビゲーションバーの高さの分だけ上げてボタンの下に入れるのに使う。
    var barHeights = BarHeights(statusBar: 0, navigationBar: 0) {
        didSet {
            guard barHeights != oldValue else { return }
            applyBannerLayout()
        }
    }
    /// ヘッダーの上端から画面の上端までの長さから、引っぱった分を除いたもの。ヘッダー画像の上を、この分だけぼかして伸ばす。
    /// スクロールに合わせて設定し直す。
    var topExtension: CGFloat = 0 {
        didSet { applyTopExtension() }
    }
    /// 一覧の一番上からさらに引っぱっている長さ。ヘッダー画像はその分だけ上へずらして画面に止め、下の内容だけを下げる。
    /// 画像を拡大して隙間を埋めることはしない。
    var pulledDistance: CGFloat = 0 {
        didSet {
            guard pulledDistance != oldValue else { return }
            let pin = CGAffineTransform(translationX: 0, y: -pulledDistance)
            for view in [bannerReflectionClip, bannerView, bannerCover, followedByBadge] as [UIView] {
                view.transform = pin
            }
        }
    }
    /// ヘッダー画像の上に伸ばす部分のぼかし方。
    var reflectionStyle = ProfileBannerBlur.Style(blur: 10, dim: 0.1, seam: 24) {
        didSet {
            guard reflectionStyle != oldValue else { return }
            applyBannerBlur()
        }
    }
    /// ヘッダー画像をバーの下まで上げている。画像がないアカウントでは、灰色の下地を上げても見栄えがしないため上げない。
    /// 画像を読み込む前から、画像のURLで決める。
    var extendsUnderBars: Bool { liftsBanner }

    struct BarHeights: Equatable {
        var statusBar: CGFloat
        var navigationBar: CGFloat
    }
    /// ヘッダー画像の下端の、ヘッダーの上端からの位置。
    var bannerBottom: CGFloat { bannerView.frame.maxY }
    /// 読み込んだヘッダー画像の、行ごとの明るさ。バーの下まで伸ばしていなければnil。
    private var bannerLuminance: BannerLuminance?

    private static let avatarSize: CGFloat = 80
    private static let avatarRing: CGFloat = 3

    private let emojiImages: EmojiImageStore
    private let mediaImages: MediaImageStore
    private let bannerView = ProfileBannerView()
    /// ヘッダー画像の上を、画面の上端までぼかして伸ばす部分。画像はナビゲーションバーのボタンの奥まで上げて置き（`ProfileBannerLayout`）、
    /// 届かないステータスバーの帯と、引っぱった分だけを埋める。中の画像の下端を画像の上端に合わせ、見える高さで切り抜く。
    private let bannerReflectionClip = UIView()
    private let bannerReflection = UIImageView()
    private var bannerReflectionTop: NSLayoutConstraint?
    /// 読み込んだヘッダー画像。ぼかした画像を、枠の大きさやぼかし方が変わったときに作り直すのに使う。
    private var bannerSource: CGImage?
    private var bannerBlur: ProfileBannerBlur?
    /// ぼかした画像を作ったときの、枠の縦横比とぼかし方。
    private var bannerBlurKey: (aspect: CGFloat, style: ProfileBannerBlur.Style)?
    private var bannerTop: NSLayoutConstraint?
    private var bannerHeight: NSLayoutConstraint?
    /// 置き場所を最後に決めたときの幅。
    private var measuredWidth: CGFloat = 0
    /// 制約に入れた、ヘッダー画像を置く場所。
    private var bannerLayout = ProfileBannerLayout(top: 0, height: 0)
    /// ビューアで開いている間、ヘッダー画像を隠すビュー。周りは画像をぼかして伸ばした部分なので、画面の背景の色で隠すと塗り残しのように見えるため、
    /// ぼかしたヘッダー画像で埋める。
    private let bannerCover = UIImageView()
    private var hasBannerImage = false {
        didSet {
            guard hasBannerImage != oldValue else { return }
            applyBannerLayout()
        }
    }
    private let avatarRingView = UIView()
    private let avatarView: AvatarView
    private let followButton = UIButton(configuration: .filled())
    /// 関係を読む前のボタンの中に出すインジケータ。ボタンの子に置き、関係が届いたときのクロスフェードで一緒に消えるようにする。
    /// ボタンの`showsActivityIndicator`は、場所を取るために消した文字の横に出て中央に来ないため、使わない。
    private let relationshipActivityIndicator = UIActivityIndicatorView(style: .medium)
    private let relationshipFailureStack = UIStackView()
    private let relationshipRetryButton = UIButton(configuration: .plain())
    private let relationshipFailureLabel = UILabel()
    /// フォローのボタンの行の下端をアイコンの下端に揃える。下地のあるボタンは、カプセルの縁が揃って見える。
    private var followAreaBottom: NSLayoutConstraint?
    /// 関係を読めなかったときの文字のベースラインを、アイコンの下端に揃える。
    /// 再試行のボタンには下地がなく、枠の下端で揃えると、見えている文字は枠の上下の余白の分だけ上に浮くため。
    /// 文言はどちらも日本語で、字はベースラインより下へはみ出さないので、ベースラインが見えている字の下端になる。
    private var relationshipFailureBaseline: NSLayoutConstraint?
    private let nameLabel = EmojiLabel()
    private let acctLabel = UILabel()
    /// ヘッダー画像の右下に重ねる「フォローされています」。関係が届いてから出るため、縦に並ぶ情報の中に置くと、出たときに下が動く。
    /// ヘッダー画像の上なら場所を取らない。添付ファイルのALTのバッジと同じ見た目にする。
    private let followedByBadge = PaddedLabel()
    private let noteLabel = LinkLabel()
    private let fieldsStack = UIStackView()
    private let remoteStack = UIStackView()
    private let remoteLabel = UILabel()
    private let openOriginalButton = UIButton(configuration: .plain())
    private let tabControl = UISegmentedControl(items: ["投稿", "メディア"])
    private let filterButton = UIButton(configuration: .plain())
    /// 固定された投稿の棚。カードを画面の端まで流すため、左右の余白の外まで広げる。
    private let pinnedShelf: ProfilePinnedShelfView
    /// 投稿、フォロー、フォロワーの数。補足情報のカードの一番下に小さく出す。
    /// フォローとフォロワーは、押すとその一覧を開く。押した文字で見分けるため、文字の位置を探せるラベルにする。
    private let countsLabel = EmojiLabel()
    /// 補足情報と数の間の区切り線。補足情報がなければ出さない。
    private let fieldsDivider = UIView()
    /// 補足情報の行どうしの間の区切り線。カードの色に合わせて塗り直す。
    private var fieldRowDividers: [UIView] = []
    /// 補足情報のカードで、数の行の上と下に空ける余白。上は区切り線から、下はほかのサーバーのアカウントの行まで。
    var countsSpacing: CGFloat = 14 {
        didSet {
            guard countsSpacing != oldValue else { return }
            applyCountsSpacing()
        }
    }
    /// 自己紹介を切っているときに、「さらに表示」の手前で文字をぼかす幅。
    var noteFadeWidth: CGFloat {
        get { noteView.fadeWidth }
        set { noteView.fadeWidth = newValue }
    }
    /// 補足情報、数、ほかのサーバーのアカウントであることをまとめたカード。
    private let aboutBox = UIStackView()
    /// 自己紹介を3行で切っているときに、その場で全文に広げるボタン。最後の行の右端に重ねる。
    private let moreButton = UIButton(configuration: .plain())
    private lazy var noteView = ProfileNoteView(label: noteLabel, button: moreButton)
    /// 自己紹介を全文に広げた。別のアカウントを出したら切った状態に戻す。
    private var isNoteExpanded = false
    /// 自己紹介を切るときの行数。
    private static let collapsedNoteLines = 3
    /// 固定された投稿の棚より下（タブ）。一覧を出すまで隠し、一覧と一緒に出す。
    /// 先に出すと、一覧と一緒に届く棚が後から差し込まれ、タブが下へずれるため。
    private var sections: [UIView] = []
    private var isSectionsRevealed = false
    /// 自己紹介を余白付きで包んだもの。自己紹介がなければ、余白ごと隠す。
    private var noteContainer: UIView?
    private var content: Content?
    private var bannerTask: Task<Void, Never>?
    private var bannerURL: URL?
    /// カードの色の、確保するコントラストとダークモードでの暗くし方。端末の「コントラストを上げる」がオンなら、目標を上げて使う。
    var accentOptions = ProfileCardPalette.Options()
    /// アイコンが届いてカードの色が変わるときの、クロスディゾルブの時間。
    var accentFadeDuration: TimeInterval = 0.3
    /// 画面のティントカラーを変えるときに呼ぶ。nilならシステムの色に戻す。
    var onChangeScreenTint: ((UIColor?) -> Void)?
    /// 塗りつぶしたフォローのボタンの地と文字の色。nilならシステムの色。
    private var filledButtonColors: (fill: UIColor, foreground: UIColor)?
    /// アイコンから作った、カードの色。アイコンがまだないか、透明なアイコンならnilで、カードはシステムの色にする。
    private var avatarAccent: ProfileAccentColor?

    init(emojiImages: EmojiImageStore, mediaImages: MediaImageStore, avatarImages: AvatarImageStore) {
        self.emojiImages = emojiImages
        self.mediaImages = mediaImages
        avatarView = AvatarView(store: avatarImages)
        pinnedShelf = ProfilePinnedShelfView(emojiImages: emojiImages, mediaImages: mediaImages)
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: ProfileHeaderView, _) in
            view.applyAccent()
        }
        avatarView.onShowImage = { [weak self] image, arrived in
            // 読み込みの間に描く空の画像では、色を消さない。消すと、同じ人のアイコンを読み直すたびに、システムの色を挟んで点滅するため。
            // 別の人に変わったときは、applyで消す。
            guard let self, let image else { return }
            let accent = ProfileAccentColor(uiImage: image)
            guard accent != avatarAccent else { return }
            avatarAccent = accent
            // 端末に残っていた画像は、開いたときにはもう描けているので、すぐに色を付ける。部品カタログでは、ここで動かすと、クロスディゾルブが終わらずにレイヤーに残った（プロフィールの画面では残らなかった）。
            applyAccent(animated: arrived)
        }
        bannerView.contentMode = .scaleAspectFill
        bannerView.clipsToBounds = true
        bannerView.backgroundColor = .secondarySystemFill

        // 伸ばしたぼかしを描くビューがヘッダー画像の手前に重なり、タップを受けるため、伸ばす部品の側でタップを受ける。ぼかした部分をタップしても開く。
        bannerView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openHeader)))
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openAvatar)))
        imageMenuInteractions = [
            .header: imageMenuInteraction(on: bannerView, for: .header),
            .avatar: imageMenuInteraction(on: avatarView, for: .avatar),
        ]
        textMenuInteractions = [
            textMenuInteraction(on: nameLabel, for: .displayName),
            textMenuInteraction(on: noteView, for: .note),
        ]
        for (view, label) in [(bannerView, "ヘッダー画像"), (avatarView, "アイコン")] as [(UIView, String)] {
            view.isUserInteractionEnabled = true
            view.isAccessibilityElement = true
            view.accessibilityLabel = label
            view.accessibilityTraits = [.image, .button]
        }

        // アイコンと「フォローされています」はヘッダー画像に重なるため、ヘッダー画像を開閉する間も手前に見せる。
        // 「フォローされています」はアカウントについての表示で、画像に重ねた表示ではないため、画像と一緒には動かさない。
        bannerView.overlappingViews = [avatarRingView, avatarView, followedByBadge]

        avatarRingView.backgroundColor = .systemBackground
        avatarRingView.layer.cornerCurve = .continuous

        followButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if content?.followState == .myself {
                onEditProfile?()
            } else {
                onToggleFollow?(followButton)
            }
        }, for: .primaryActionTriggered)
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        relationshipActivityIndicator.translatesAutoresizingMaskIntoConstraints = false
        relationshipActivityIndicator.isUserInteractionEnabled = false
        followButton.addSubview(relationshipActivityIndicator)
        NSLayoutConstraint.activate([
            relationshipActivityIndicator.centerXAnchor.constraint(equalTo: followButton.centerXAnchor),
            relationshipActivityIndicator.centerYAnchor.constraint(equalTo: followButton.centerYAnchor),
        ])

        // フォローの関係を読めなかったら、ボタンを黙って消さず、その場所で読めなかったことと再試行を示す。
        relationshipFailureLabel.text = "読み込みエラー"
        relationshipFailureLabel.font = .preferredFont(forTextStyle: .footnote)
        relationshipFailureLabel.adjustsFontForContentSizeCategory = true
        relationshipFailureLabel.textColor = .secondaryLabel
        relationshipFailureLabel.numberOfLines = 0
        relationshipFailureLabel.textAlignment = .right
        relationshipRetryButton.configuration?.title = "再試行"
        relationshipRetryButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
        relationshipRetryButton.configuration?.imagePadding = 4
        relationshipRetryButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        relationshipRetryButton.accessibilityHint = "フォローの状態を読み込み直します"
        relationshipRetryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        relationshipRetryButton.addAction(UIAction { [weak self] _ in self?.onRetryRelationship?() }, for: .primaryActionTriggered)
        relationshipFailureStack.axis = .horizontal
        relationshipFailureStack.alignment = .lastBaseline
        relationshipFailureStack.spacing = 0
        relationshipFailureStack.addArrangedSubview(relationshipFailureLabel)
        relationshipFailureStack.addArrangedSubview(relationshipRetryButton)
        let followArea = UIStackView(arrangedSubviews: [relationshipFailureStack, followButton])
        followArea.axis = .horizontal
        followArea.alignment = .center

        nameLabel.numberOfLines = 0
        acctLabel.numberOfLines = 0
        followedByBadge.textColor = .white
        followedByBadge.backgroundColor = MediaBadgeView.backgroundColor
        followedByBadge.layer.cornerRadius = MediaBadgeView.cornerRadius
        followedByBadge.layer.cornerCurve = .continuous
        followedByBadge.clipsToBounds = true
        followedByBadge.text = "フォローされています"
        // 触れたらヘッダー画像を開けるよう、タップは下のヘッダー画像に通す。
        followedByBadge.isUserInteractionEnabled = false
        noteLabel.numberOfLines = Self.collapsedNoteLines
        noteLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
        fieldsStack.axis = .vertical
        fieldsStack.spacing = 8
        countsLabel.numberOfLines = 0
        countsLabel.isUserInteractionEnabled = true
        countsLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(countsTapped)))
        countsLabel.accessibilityCustomActions = ProfileCountList.allCases.map { list in
            UIAccessibilityCustomAction(name: list.accessibilityName) { [weak self] _ in
                self?.onOpenCountList?(list)
                return true
            }
        }

        moreButton.configuration?.title = "さらに表示"
        moreButton.configuration?.contentInsets = .zero
        moreButton.isHidden = true
        moreButton.addAction(UIAction { [weak self] _ in self?.expandNote() }, for: .primaryActionTriggered)

        // ほかのサーバーのアカウントであることは、補足情報のカードの中に1行で出す。投稿がこのサーバーに届いた分だけなのは、押して開く元のサーバーで分かる。
        remoteLabel.font = .preferredFont(forTextStyle: .footnote)
        remoteLabel.adjustsFontForContentSizeCategory = true
        remoteLabel.textColor = .secondaryLabel
        remoteLabel.text = "他のサーバーのアカウント"
        remoteLabel.setContentHuggingPriority(.required, for: .horizontal)
        let openOriginal = openOriginalButton
        openOriginal.configuration?.title = "元のサーバーで開く"
        openOriginal.configuration?.image = UIImage(systemName: "safari")
        openOriginal.configuration?.imagePadding = 4
        openOriginal.configuration?.contentInsets = .zero
        openOriginal.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        openOriginal.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .footnote)
            return attributes
        }
        openOriginal.contentHorizontalAlignment = .trailing
        openOriginal.addAction(UIAction { [weak self] _ in self?.onOpenOriginal?() }, for: .primaryActionTriggered)
        remoteStack.axis = .horizontal
        // ボタンには、ベースラインで揃える設定が効かず、文字が上にずれる。どちらも同じ大きさの文字なので、中心で揃える。
        remoteStack.alignment = .center
        remoteStack.spacing = 8
        remoteStack.addArrangedSubview(remoteLabel)
        remoteStack.addArrangedSubview(openOriginal)

        tabControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onSelectTab?(self.tabControl.selectedSegmentIndex == 1 ? .media : .posts)
        }, for: .valueChanged)
        filterButton.showsMenuAsPrimaryAction = true
        filterButton.accessibilityLabel = "投稿の絞り込み"
        filterButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        filterButton.setContentHuggingPriority(.required, for: .horizontal)

        let tabRow = UIStackView(arrangedSubviews: [tabControl, filterButton])
        tabRow.spacing = 8
        tabRow.alignment = .center

        // 名前とハンドル、自己紹介、補足情報のカード、固定された投稿の棚、タブの順に置く。
        let margin: CGFloat = 16
        func inset(_ views: [UIView], spacing: CGFloat = 0) -> UIStackView {
            let stack = UIStackView(arrangedSubviews: views)
            stack.axis = .vertical
            stack.spacing = spacing
            stack.isLayoutMarginsRelativeArrangement = true
            stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
            return stack
        }
        let identity = inset([nameLabel, acctLabel], spacing: 2)

        // 自己紹介はカードにせず、名前の下にそのまま置く。
        let note = inset([noteView])
        // 補足情報は、数とほかのサーバーのアカウントであることと一緒に、角の丸いカードにまとめる。
        // 補足情報と数の間にも、補足情報の行どうしと同じ区切り線を引く。
        fieldsDivider.backgroundColor = .separator
        fieldsDivider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        for view in [fieldsStack, fieldsDivider, countsLabel, remoteStack] as [UIView] {
            aboutBox.addArrangedSubview(view)
        }
        aboutBox.axis = .vertical
        aboutBox.spacing = 12
        aboutBox.setCustomSpacing(8, after: fieldsStack)
        applyCountsSpacing()
        aboutBox.backgroundColor = .secondarySystemFill
        aboutBox.layer.cornerRadius = 16
        aboutBox.layer.cornerCurve = .continuous
        aboutBox.isLayoutMarginsRelativeArrangement = true
        aboutBox.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        let about = inset([aboutBox])

        pinnedShelf.isHidden = true
        let tabs = inset([tabRow])
        let contentStack = UIStackView()
        for view in [identity, note, about, pinnedShelf, tabs] as [UIView] {
            contentStack.addArrangedSubview(view)
        }
        noteContainer = note
        // 固定された投稿の棚は一覧と一緒に出すので、その下のタブも一緒に出す。上の自己紹介とカードは、棚が出ても動かないので先に出す。
        sections = [tabs]
        applySectionsVisibility()
        contentStack.axis = .vertical
        contentStack.spacing = 24
        contentStack.setCustomSpacing(12, after: identity)
        contentStack.setCustomSpacing(16, after: note)

        bannerReflectionClip.clipsToBounds = true
        bannerReflectionClip.isUserInteractionEnabled = false
        bannerReflectionClip.isHidden = true
        bannerReflection.translatesAutoresizingMaskIntoConstraints = false
        bannerReflectionClip.addSubview(bannerReflection)
        bannerCover.backgroundColor = .systemBackground
        // 隠すビューの画像は、枠に見えている範囲から作るので、枠に合わせて伸ばす。
        bannerCover.contentMode = .scaleToFill
        bannerCover.isHidden = true
        // 閉じる途中にタップし直しても開けるよう、タップは下に通す。
        bannerCover.isUserInteractionEnabled = false
        bannerView.cover = bannerCover
        bannerView.onChangeConcealment = { [weak self] in self?.applyReflectionImage() }

        for view in [bannerReflectionClip, bannerView, bannerCover, followedByBadge, avatarRingView, avatarView, followArea, contentStack] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let bannerReflectionTop = bannerReflectionClip.topAnchor.constraint(equalTo: topAnchor)
        self.bannerReflectionTop = bannerReflectionTop
        let bannerTop = bannerView.topAnchor.constraint(equalTo: topAnchor)
        self.bannerTop = bannerTop
        let bannerHeight = bannerView.heightAnchor.constraint(equalToConstant: 0)
        self.bannerHeight = bannerHeight
        NSLayoutConstraint.activate([
            bannerReflectionTop,
            bannerTop,
            bannerHeight,
            bannerReflectionClip.leadingAnchor.constraint(equalTo: leadingAnchor),
            bannerReflectionClip.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerReflectionClip.bottomAnchor.constraint(equalTo: bannerView.topAnchor),
            bannerReflection.leadingAnchor.constraint(equalTo: bannerReflectionClip.leadingAnchor),
            bannerReflection.trailingAnchor.constraint(equalTo: bannerReflectionClip.trailingAnchor),
            bannerReflection.bottomAnchor.constraint(equalTo: bannerReflectionClip.bottomAnchor),
            bannerReflection.heightAnchor.constraint(equalTo: bannerView.heightAnchor, multiplier: ProfileBannerBlur.reflectionHeightRatio),
            bannerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bannerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerCover.topAnchor.constraint(equalTo: bannerView.topAnchor),
            bannerCover.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor),
            bannerCover.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor),
            bannerCover.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor),

            // 添付ファイルのタイルのバッジと同じく、端から6pt離す。
            followedByBadge.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor, constant: -6),
            followedByBadge.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -6),

            // アイコンはヘッダー画像の下端に半分かける。
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin + Self.avatarRing),
            avatarView.centerYAnchor.constraint(equalTo: bannerView.bottomAnchor),

            avatarRingView.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarRingView.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            avatarRingView.widthAnchor.constraint(equalTo: avatarView.widthAnchor, constant: Self.avatarRing * 2),
            avatarRingView.heightAnchor.constraint(equalTo: avatarView.heightAnchor, constant: Self.avatarRing * 2),

            // フォローのボタンの下端をアイコンの下端に揃え、どちらからも名前まで同じ間を空ける。
            // 文字を大きくしてボタンが高くなったときは上に伸び、名前ではなくヘッダー画像にかかる。
            followArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            followArea.leadingAnchor.constraint(greaterThanOrEqualTo: avatarRingView.trailingAnchor, constant: 12),

            contentStack.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize).isActive = true
        followAreaBottom = followArea.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor)
        followAreaBottom?.isActive = true
        relationshipFailureBaseline = relationshipFailureLabel.lastBaselineAnchor.constraint(equalTo: avatarView.bottomAnchor)
    }

    private func applyTopExtension() {
        // 画像がなければ伸ばさない。画像の上端が画面の上端より上へ流れたら、高さが負にならないよう、伸ばす部分の上端を画像の上端に止める。
        bannerReflectionTop?.constant = min(-topExtension, bannerLayout.top)
        bannerReflectionClip.isHidden = !hasBannerImage
    }

    /// 一覧はヘッダーの大きさを、幅を決めてから測る。画像の高さは幅で決まるため、測る前に幅に合わせて置き直す。
    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        applyBannerLayout(width: targetSize.width, notifies: false)
        updateMoreButton(width: targetSize.width)
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }

    override func layoutSubviews() {
        applyBannerLayout(width: bounds.width, notifies: false)
        updateMoreButton(width: bounds.width)
        super.layoutSubviews()
    }

    /// ヘッダーの外へ上にはみ出したヘッダー画像も、タップを受ける。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || bannerView.frame.contains(point)
    }

    /// 並べる前（幅が0）に置き場所を決め直すときは、一覧が最後に測った幅を使う。幅0で決めると画像の高さが0になり、その高さで測られるため。
    private func applyBannerLayout() {
        applyBannerLayout(width: bounds.width > 0 ? bounds.width : measuredWidth, notifies: true)
    }

    private func applyBannerLayout(width: CGFloat, notifies: Bool) {
        guard width > 0 else { return }
        measuredWidth = width
        let image = bannerView.image
        let layout = ProfileBannerLayout(
            width: width,
            imageAspect: hasBannerImage ? image.map { $0.size.height / $0.size.width } : nil,
            statusBarHeight: barHeights.statusBar,
            navigationBarHeight: barHeights.navigationBar,
            liftsUnderBars: liftsBanner
        )
        applyTopExtension()
        guard layout != bannerLayout else { return }
        defer { applyBannerBlur(width: width) }
        let changesHeight = layout.bottom != bannerLayout.bottom
        bannerLayout = layout
        bannerTop?.constant = layout.top
        bannerHeight?.constant = layout.height
        applyTopExtension()
        if notifies, changesHeight {
            onChangeBannerLayout?()
        }
    }

    /// ヘッダー画像をバーの下まで上げるか。読み込む前から上げておき、画像が届いたときにヘッダーの下が動かないようにする。
    /// Mastodonは、ヘッダー画像を設定していないアカウントにも`missing.png`という名前の画像のURLを返すため、その名前なら上げない。
    /// 名前で分からなくても、届いた画像が1×1の透明な画像なら上げない。
    private var liftsBanner: Bool {
        guard let bannerURL, bannerURL.lastPathComponent != "missing.png" else { return false }
        return bannerView.image == nil || hasBannerImage
    }

    @objc private func openAvatar(_ gesture: UITapGestureRecognizer) {
        imageTapped(.avatar, gesture: gesture)
    }

    @objc private func openHeader(_ gesture: UITapGestureRecognizer) {
        imageTapped(.header, gesture: gesture)
    }

    /// 画像のタップに選んだ操作を行う。既定（開く）なら、今のタップの処理のまま開く。決まりはdocs/object-actions.mdにある。
    private func imageTapped(_ image: ProfileImage, gesture: UITapGestureRecognizer) {
        let interaction = imageMenuInteractions[image]
        guard !ObjectEntity.media.performsPrimary(.tap), let interaction, let view = gesture.view else {
            open(image)
            return
        }
        let point = gesture.location(in: view)
        interaction.target(at: point)?.perform(.tap, in: view, at: point)
    }

    private func open(_ image: ProfileImage) {
        guard viewerSource(for: image) != nil else { return }
        onOpenImage?(image)
    }

    /// 長押しで持ち上げ、持ち上げた画像をタップすると、タップしたときと同じく開く。
    /// ヘッダー画像は切り抜いているので、画像の全体を持ち上げる。アイコンは切り抜いておらず、形も見た目の一部なので、そのまま持ち上げる。
    private func imageMenuInteraction(on view: UIView, for image: ProfileImage) -> MediaMenuInteraction {
        let wholeImage: (@MainActor () -> UIImage?)? = switch image {
        case .header: { [weak self] in self?.viewerSource(for: image)?.loadedThumbnail }
        case .avatar: nil
        }
        let sharperImage: (@MainActor (Int) async -> UIImage?)? = switch image {
        case .header: { [weak self] maxPixelSize in
            guard let self, let url = self.bannerURL else { return nil }
            return try? await self.mediaImages.image(for: url, maxPixelSize: maxPixelSize, retriesNow: true)
        }
        case .avatar: nil
        }
        // ビューアで開くときと同じく、持ち上げている間はヘッダー画像の場所にぼかしたビューを出し、抜けて見えないようにする。
        let onLiftChange: (@MainActor (Bool) -> Void)? = switch image {
        case .header: { [weak self] isLifted in self?.bannerView.isConcealedForViewer = isLifted }
        case .avatar: nil
        }
        return MediaMenuInteraction(on: view, wholeImage: wholeImage, open: { [weak self] in
            self?.open(image)
        }, menu: { [weak self] groups in
            self?.menuForImage?(image, groups)
        }, sharperImage: sharperImage, onLiftChange: onLiftChange, offersMenu: { [weak self] _ in
            self?.viewerSource(for: image) != nil
        })
    }

    /// ビューアを開閉する起点。画像を読み込み終えていなければ、大きくして見るものがないのでnil。
    /// Mastodonは、ヘッダー画像を設定していないアカウントに1×1の透明な画像（`/headers/original/missing.png`）を返すため、それも開かない。
    func viewerSource(for image: ProfileImage) -> (any MediaViewerSource)? {
        let view: any MediaViewerSource = switch image {
        case .avatar: avatarView
        case .header: bannerView
        }
        guard let shown = view.loadedThumbnail, window != nil else { return nil }
        let pixels = CGSize(width: shown.size.width * shown.scale, height: shown.size.height * shown.scale)
        guard pixels.width > 1 || pixels.height > 1 else { return nil }
        return view
    }

    func apply(_ content: Content) {
        let previous = self.content
        self.content = content
        let account = content.account
        if previous?.account.id != account.id { avatarAccent = nil }

        avatarView.apply(AvatarView.Content(
            url: content.animatesAvatar ? account.avatar : account.avatarStatic,
            shape: content.avatarShape,
            animates: content.animatesAvatar
        ))
        avatarRingView.layer.cornerRadius = switch content.avatarShape {
        case .circle: (Self.avatarSize + Self.avatarRing * 2) / 2
        case .roundedSquare: Self.avatarSize * 0.2 + Self.avatarRing
        }
        loadBanner(account.headerStatic)

        let title = UIFont.preferredFont(forTextStyle: .title2)
        let boldTitle = title.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? title
        let animatedEmojis = content.animatesCustomEmojis ? emojiImages : nil
        nameLabel.emojiImages = animatedEmojis
        nameLabel.attributedText = RichTextRenderer(font: boldTitle, textColor: .label, emojiImages: emojiImages, language: content.glyphLanguage)
            .render(.plain(account.displayNameOrUsername, emojis: account.emojis))
        acctLabel.attributedText = acctText(of: account)

        let body = UIFont.preferredFont(forTextStyle: .body)
        let note = RichTextRenderer(font: body, textColor: .label, paragraphSpacing: 6, emojiImages: emojiImages, language: content.glyphLanguage).render(.html(account.note, emojis: account.emojis))
        noteLabel.emojiImages = animatedEmojis
        noteLabel.attributedText = note
        noteLabel.hashtagAccount = account
        noteLabel.accessibilityCustomActions = linkAccessibilityActions(in: note)
        noteLabel.isHidden = note.length == 0
        noteContainer?.isHidden = note.length == 0
        if previous?.account.id != account.id {
            isNoteExpanded = false
            noteView.finishExpanding()
        }
        noteLabel.numberOfLines = isNoteExpanded ? 0 : Self.collapsedNoteLines
        applyFields(account, language: content.glyphLanguage, animatedEmojis: animatedEmojis)
        countsLabel.attributedText = Self.countsText(of: account)
        remoteStack.isHidden = !content.isRemote
        applySectionsVisibility()
        // サーバーがプロフィールのURLを返さなかったら、開く先がないのでボタンを出さない。
        openOriginalButton.isHidden = account.url == nil

        // 関係が届いたときと、フォローしたり外したりして関係や送っている途中の表示が替わったときは、ボタンをクロスフェードする。
        // 文字と色だけでなく、カプセルの幅も替わるため、並べ直しもクロスフェードの中で行う。外で行うと、幅だけが1コマで替わる。
        let changesFollow = previous.map { $0.followState != content.followState || $0.isChangingFollow != content.isChangingFollow } ?? false
        if changesFollow, followRevealDuration > 0, window != nil, !UIAccessibility.isReduceMotionEnabled {
            // 補足情報の行は上で作り直したばかりで、まだ並べていない。クロスフェードの中で初めて並べると、行が大きさ0から伸び、
            // 文字が空になったり縦に潰れたりして見えるため、ボタンを替える前に並べ終えておく。
            layoutIfNeeded()
            let options: UIView.AnimationOptions = [.transitionCrossDissolve, .allowUserInteraction]
            UIView.transition(with: followButton, duration: followRevealDuration, options: options) {
                self.applyFollowButton(content)
                self.layoutIfNeeded()
            }
            UIView.transition(with: followedByBadge, duration: followRevealDuration, options: options) {
                self.applyFollowedByBadge(content)
            }
        } else {
            applyFollowButton(content)
            applyFollowedByBadge(content)
        }
        tabControl.selectedSegmentIndex = content.tab == .media ? 1 : 0
        // メディアの一覧では使えないが、消すとタブの幅が変わって動くため、場所を残したまま押せなくする。
        filterButton.isEnabled = content.tab == .posts
        applyFilterButton(content.postsFilter)
        applyAccent()
    }

    /// 補足情報のカードと固定された投稿のカード、画面のティントカラーに、アイコンから作った色を付ける。
    /// - Parameter animated: 色が変わるなら、ヘッダーごとクロスディゾルブで移す。画面に出ていないときは、すぐに変える。
    ///   文字の色やボタンの色は、色の変化として動かせないため、ヘッダーをまとめて移す。移る間もタップとスクロールを受け付ける。
    private func applyAccent(animated: Bool = false) {
        guard animated, window != nil, accentFadeDuration > 0 else {
            applyAccentNow()
            return
        }
        UIView.transition(with: self, duration: accentFadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
            self.applyAccentNow()
        }
    }

    private func applyAccentNow() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let options = traitCollection.accessibilityContrast == .high ? accentOptions.raisingContrast() : accentOptions
        let appearance = avatarAccent.map { ProfileAccentAppearance(palette: ProfileCardPalette(color: $0, options: options, isDark: isDark)) }
        if let appearance {
            appearance.apply(to: aboutBox)
        } else {
            ProfileAccentAppearance.reset(aboutBox)
        }
        ProfileAccentAppearance.recolorSecondaryText(in: aboutBox, to: appearance?.secondaryText)
        // 属性のない文字のラベルは、上の塗り替えでは変わらないので、直接塗る。
        remoteLabel.textColor = appearance?.secondaryText ?? .secondaryLabel
        ProfileAccentAppearance.restyleLinks(in: aboutBox, underline: appearance != nil, badge: appearance?.text)
        for divider in [fieldsDivider] + fieldRowDividers {
            divider.backgroundColor = appearance?.separator ?? .separator
        }
        let underlinesScreenLinks = appearance?.underlinesScreenLinks ?? false
        ProfileAccentAppearance.restyleLinks(in: noteLabel, underline: underlinesScreenLinks, badge: nil)
        var moreTitle = AttributedString("さらに表示")
        if underlinesScreenLinks { moreTitle.underlineStyle = .single }
        moreButton.configuration?.attributedTitle = moreTitle
        pinnedShelf.accent = appearance
        // 本文と色で見分けられるティントカラーだけを、画面全体に当てる。見分けられないときは、下線を引けるヘッダーの中だけに当て、
        // 投稿の一覧はシステムの色のままにする。投稿の本文のリンクは、タイムラインの行と同じ描き方で、下線を引けないため。
        if let appearance, appearance.underlinesScreenLinks {
            tintColor = appearance.screenTint
            onChangeScreenTint?(nil)
        } else {
            tintColor = nil
            onChangeScreenTint?(appearance?.screenTint)
        }
        let colors = appearance.map { (fill: $0.background, foreground: $0.text) }
        if colors?.fill != filledButtonColors?.fill || colors?.foreground != filledButtonColors?.foreground {
            filledButtonColors = colors
            if let content { applyFollowButton(content) }
        }
    }

    private func acctText(of account: Account) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let text = NSMutableAttributedString(string: "@\(account.acct)", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        let symbols = [account.locked ? "lock.fill" : nil, account.bot ? "cpu" : nil].compactMap { $0 }
        for name in symbols {
            guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)) else { continue }
            text.append(NSAttributedString(string: " "))
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal))))
        }
        return text
    }

    /// - Parameter animatedEmojis: アニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら動かさない。
    private func applyFields(_ account: Account, language: String, animatedEmojis: EmojiImageStore?) {
        fieldsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fieldRowDividers = []
        fieldMenuInteractions = []
        fieldsStack.isHidden = account.fields.isEmpty
        fieldsDivider.isHidden = account.fields.isEmpty
        fieldsStack.spacing = 0
        let nameFont = UIFont.preferredFont(forTextStyle: .footnote)
        let valueFont = UIFont.preferredFont(forTextStyle: .subheadline)
        for (index, field) in account.fields.enumerated() {
            let nameLabel = EmojiLabel()
            nameLabel.numberOfLines = 0
            nameLabel.emojiImages = animatedEmojis
            nameLabel.attributedText = RichTextRenderer(font: nameFont, textColor: .secondaryLabel, emojiImages: emojiImages, language: language)
                .render(.plain(field.name, emojis: account.emojis))
            let valueLabel = LinkLabel()
            valueLabel.numberOfLines = 0
            valueLabel.emojiImages = animatedEmojis
            valueLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
            valueLabel.hashtagAccount = account
            let value = NSMutableAttributedString(attributedString: RichTextRenderer(font: valueFont, textColor: .label, emojiImages: emojiImages, language: language)
                .render(.profileField(field.value, emojis: account.emojis)))
            if field.verifiedAt != nil,
               let check = UIImage(systemName: "checkmark.seal.fill", withConfiguration: UIImage.SymbolConfiguration(font: valueFont, scale: .small)) {
                // リンク先にこのアカウントへのリンクがあると確かめられた値に付くチェックマーク。
                value.append(NSAttributedString(string: " "))
                let badge = NSMutableAttributedString(attachment: NSTextAttachment(image: check.withTintColor(.systemGreen, renderingMode: .alwaysOriginal)))
                badge.addAttribute(.profileVerifiedBadge, value: true, range: NSRange(location: 0, length: badge.length))
                value.append(badge)
                valueLabel.accessibilityValue = "確認済み"
            }
            valueLabel.attributedText = value
            valueLabel.accessibilityCustomActions = linkAccessibilityActions(in: value)
            let row = UIStackView(arrangedSubviews: [nameLabel, valueLabel])
            row.axis = .vertical
            row.spacing = 2
            if !fieldsStack.arrangedSubviews.isEmpty {
                // 設定のグループと同じく、行の間に区切り線を引く。
                let divider = UIView()
                divider.backgroundColor = .separator
                fieldRowDividers.append(divider)
                divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
                let spacer = UIStackView(arrangedSubviews: [divider])
                spacer.isLayoutMarginsRelativeArrangement = true
                spacer.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
                fieldsStack.addArrangedSubview(spacer)
            }
            fieldsStack.addArrangedSubview(row)
            // 補足情報の行は、文字の色をカードの色に合わせているため、カードの色を下地にして持ち上げる。色がなければ既定の下地にする。
            fieldMenuInteractions.append(textMenuInteraction(on: row, for: .field(index)) { [weak self] in
                guard let self, avatarAccent != nil else { return nil }
                return aboutBox.backgroundColor
            })
        }
    }

    private func textMenuInteraction(
        on view: UIView,
        for part: ProfileTextPart,
        previewBackground: @escaping @MainActor () -> UIColor? = { nil }
    ) -> ProfileTextMenuInteraction {
        let lifecycle = MenuLifecycle(
            willShow: { [weak self] in self?.textMenuLifecycle.willShow() },
            willEnd: { [weak self] in self?.textMenuLifecycle.willEnd() },
            didHide: { [weak self] in self?.textMenuLifecycle.didHide() }
        )
        return ProfileTextMenuInteraction(on: view, menu: { [weak self] in self?.menuForText?(part) }, previewBackground: previewBackground, lifecycle: lifecycle)
    }

    /// 読み上げで、リンクを開く操作。
    private func linkAccessibilityActions(in text: NSAttributedString) -> [UIAccessibilityCustomAction] {
        LinkLabel.links(in: text).map { text, destination in
            UIAccessibilityCustomAction(name: text) { [weak self] _ in
                self?.onOpenLink?(destination)
                return true
            }
        }
    }

    /// 塗りつぶさないボタン（「フォロー中」など）の見た目。カードに色を付けているときは、画面のティントカラーで薄く塗り、塗りつぶしたボタンと色を揃える。
    private func secondaryButtonConfiguration() -> UIButton.Configuration {
        filledButtonColors == nil ? .gray() : .tinted()
    }

    private func applyFollowButton(_ content: Content) {
        let title: String?
        var configuration: UIButton.Configuration
        // 関係を読む前は、届いたときに何もない所から出ないよう、文字を消したボタンで場所を取っておく。
        // 幅は、一番多い「フォローする」に合わせる。
        let isPlaceholder = content.followState == .unknown
        switch content.followState {
        case .myself:
            title = "プロフィールを編集"
            configuration = secondaryButtonConfiguration()
        case .loadFailed, .blocked:
            title = nil
            configuration = .filled()
        case .unknown:
            title = "フォローする"
            configuration = secondaryButtonConfiguration()
            configuration.baseForegroundColor = .clear
        case .notFollowing(let locked):
            title = locked ? "フォローをリクエスト" : "フォローする"
            configuration = .filled()
            configuration.baseBackgroundColor = filledButtonColors?.fill
            configuration.baseForegroundColor = filledButtonColors?.foreground
        case .requested:
            title = "リクエスト中"
            configuration = secondaryButtonConfiguration()
        case .following:
            title = "フォロー中"
            configuration = secondaryButtonConfiguration()
        }
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.showsActivityIndicator = content.isChangingFollow
        followButton.configuration = configuration
        followButton.isHidden = title == nil
        followButton.isEnabled = !content.isChangingFollow
        // 押せない見た目にすると、消した文字が灰色で出てしまうため、見た目はそのままで触れないだけにする。
        followButton.isUserInteractionEnabled = !isPlaceholder
        followButton.accessibilityLabel = isPlaceholder ? "フォローの状態を読み込み中" : nil
        followButton.accessibilityTraits = isPlaceholder ? [.button, .notEnabled] : .button

        applyRelationshipActivity(isPlaceholder && content.showsRelationshipActivity)

        relationshipFailureStack.isHidden = content.followState != .loadFailed
        let alignsFailureText = content.followState == .loadFailed
        // 先に外してから付け、2つが同時に効いて矛盾しないようにする。
        for constraint in [followAreaBottom, relationshipFailureBaseline].compactMap({ $0 }) where constraint.isActive {
            constraint.isActive = false
        }
        (alignsFailureText ? relationshipFailureBaseline : followAreaBottom)?.isActive = true
        relationshipRetryButton.configuration?.showsActivityIndicator = content.isReloadingRelationship
        relationshipRetryButton.isEnabled = !content.isReloadingRelationship
    }

    /// 関係を待つのが長引いたら、ボタンの中のインジケータを浮かび上がらせる。消すときは、関係が届いたときのボタンのクロスフェードに任せる。
    private func applyRelationshipActivity(_ shows: Bool) {
        guard shows != relationshipActivityIndicator.isAnimating else { return }
        guard shows else {
            relationshipActivityIndicator.stopAnimating()
            return
        }
        relationshipActivityIndicator.alpha = 0
        relationshipActivityIndicator.startAnimating()
        UIView.animateSmoothly(duration: window == nil ? 0 : followRevealDuration) {
            self.relationshipActivityIndicator.alpha = 1
        }
    }

    private func applyFollowedByBadge(_ content: Content) {
        followedByBadge.isHidden = !content.followedBy || content.followState == .myself
        followedByBadge.font = MediaBadgeView.font(for: traitCollection)
    }

    private func applyFilterButton(_ filter: ProfilePostsFilter) {
        let isFiltered = filter != .standard
        filterButton.configuration?.image = UIImage(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        let shown = [filter.showsReplies ? "返信を表示" : nil, filter.showsBoosts ? "ブーストを表示" : nil].compactMap { $0 }
        filterButton.accessibilityValue = shown.isEmpty ? "返信とブーストを表示しない" : shown.joined(separator: "、")
        filterButton.menu = filterMenu(filter)
        // メニューを開いたまま切り替えたときは、開いているメニューのチェックも書き換える。
        filterButton.contextMenuInteraction?.updateVisibleMenu { [weak self] _ in
            self?.filterMenu(filter) ?? UIMenu()
        }
    }

    private func filterMenu(_ filter: ProfilePostsFilter) -> UIMenu {
        let replies = UIAction(title: "返信を表示", image: Self.checkImage(filter.showsReplies), attributes: .keepsMenuPresented) { [weak self] _ in
            var changed = filter
            changed.showsReplies.toggle()
            self?.onChangePostsFilter?(changed)
        }
        let boosts = UIAction(title: "ブーストを表示", image: Self.checkImage(filter.showsBoosts), attributes: .keepsMenuPresented) { [weak self] _ in
            var changed = filter
            changed.showsBoosts.toggle()
            self?.onChangePostsFilter?(changed)
        }
        return UIMenu(title: "自分のスレッドの続きは、返信を隠しても表示します", children: [replies, boosts])
    }

    /// メニューのチェック。UIActionのstateを使うと、どちらもオフにしたときにメニューがチェックの列を詰め、文字が左へ動く。
    /// そのためチェックを画像として描き、オフでも同じ大きさの透明な画像で列を残す。
    /// stateを使わないため、読み上げではメニューの各項目が選択済みと読まれない。いまの絞り込みは、ボタンのaccessibilityValueで伝える。
    private static func checkImage(_ isOn: Bool) -> UIImage? {
        let image = UIImage(systemName: "checkmark")
        return isOn ? image : image?.withTintColor(.clear, renderingMode: .alwaysOriginal)
    }

    /// URLがなければ、ヘッダー画像を出さずに下地の色のままにする。
    private func loadBanner(_ url: URL?) {
        guard url != bannerURL else { return }
        bannerURL = url
        bannerTask?.cancel()
        setBanner(nil)
        guard let url else { return }
        let pixelSize = Int((max(bounds.width, 402) * traitCollection.displayScale).rounded(.up))
        if let cached = mediaImages.cachedImage(for: url, maxPixelSize: pixelSize) {
            setBanner(cached)
            return
        }
        bannerTask = Task { [weak self, mediaImages] in
            guard let image = try? await mediaImages.image(for: url, maxPixelSize: pixelSize), let self, !Task.isCancelled, self.bannerURL == url else { return }
            UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.setBanner(image)
            }
        }
    }

    private func setBanner(_ image: UIImage?) {
        bannerView.image = image
        let isReal = image.map(Self.isRealBanner) ?? false
        let cgImage = isReal ? image?.cgImage : nil
        bannerSource = cgImage
        bannerBlurKey = nil
        hasBannerImage = isReal
        // 画像の縦横比と、上げるかどうかで置き場所が変わる。
        applyBannerLayout()
        applyBannerBlur()
        onChangeExtendsUnderBars?()
    }

    private func applyBannerBlur() {
        applyBannerBlur(width: bounds.width)
    }

    /// 隠すビューを出している間は、それとつながる一様なぼかしにする。
    private func applyReflectionImage() {
        bannerReflection.image = bannerView.isConcealedForViewer ? bannerBlur?.uniformReflection : bannerBlur?.reflection
    }

    /// 伸ばす部分と隠すビューの画像を、今の枠の縦横比とぼかし方で作る。同じ条件で作ってあれば作り直さない。
    private func applyBannerBlur(width: CGFloat) {
        guard let bannerSource, width > 0, bannerLayout.height > 0 else {
            bannerBlur = nil
            bannerLuminance = nil
            bannerReflection.image = nil
            bannerCover.image = nil
            return
        }
        let aspect = bannerLayout.height / width
        if let key = bannerBlurKey, key.aspect == aspect, key.style == reflectionStyle { return }
        bannerBlurKey = (aspect, reflectionStyle)
        let blur = ProfileBannerBlur.make(from: bannerSource, frameWidth: width, frameAspect: aspect, style: reflectionStyle)
        // 明るさも、ぼかしと同じく枠に見えている範囲で測る。
        bannerLuminance = BannerLuminance(image: bannerSource, frameAspect: aspect)
        bannerBlur = blur
        applyReflectionImage()
        bannerCover.image = blur?.cover
    }

    /// 自己紹介を全文に広げる。下の内容だけが下がり、ヘッダーと上の棚は動かない（`headerDidChangeSize`）。
    private func expandNote() {
        isNoteExpanded = true
        noteLabel.numberOfLines = 0
        let duration = window != nil && !UIAccessibility.isReduceMotionEnabled ? noteExpandDuration : 0
        noteView.expand(duration: duration)
        onExpandNote?(duration)
    }

    /// 自己紹介が切った行数に収まらないときだけ、「さらに表示」を出す。測る幅は、一覧がヘッダーを測る幅から、左右の余白を引いたもの。
    private func updateMoreButton(width: CGFloat) {
        guard !isNoteExpanded, !noteLabel.isHidden, width > 0 else {
            if !moreButton.isHidden {
                moreButton.isHidden = true
                noteView.setNeedsLayout()
            }
            return
        }
        let textWidth = width - 16 * 2
        // 段落の間隔を含めて、ラベルが描くのと同じ測り方で比べる。
        let bounds = CGRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)
        let full = noteLabel.textRect(forBounds: bounds, limitedToNumberOfLines: 0).height
        let limited = noteLabel.textRect(forBounds: bounds, limitedToNumberOfLines: Self.collapsedNoteLines).height
        let isHidden = full <= limited + 1
        if moreButton.isHidden != isHidden {
            moreButton.isHidden = isHidden
            noteView.setNeedsLayout()
        }
    }

    /// 固定された投稿の棚に並べる投稿を変える。空なら棚を見出しごと隠す。中身が変わって高さが変わりうるならtrue。
    @discardableResult
    func setPinned(_ items: [ProfileShelfItem], glyphLanguage: String) -> Bool {
        let wasHidden = pinnedShelf.isHidden
        let previous = pinnedShelf.items
        pinnedShelf.setItems(items, glyphLanguage: glyphLanguage)
        pinnedShelf.isHidden = items.isEmpty
        return wasHidden != pinnedShelf.isHidden || previous != items
    }

    private func applyCountsSpacing() {
        aboutBox.setCustomSpacing(countsSpacing, after: fieldsDivider)
        aboutBox.setCustomSpacing(countsSpacing, after: countsLabel)
    }

    /// 固定された投稿のカードの本文に、`urls`のカスタム絵文字を使っているものがあれば描き直す。描き直したらtrue。
    @discardableResult
    func redrawPinned(ifUsing urls: Set<URL>) -> Bool {
        guard pinnedShelf.uses(emojiURLs: urls) else { return false }
        pinnedShelf.redraw()
        return true
    }

    /// 固定された投稿の棚より下を出す。一覧と一緒に出すまでは隠す。変わったらtrue。
    @discardableResult
    func setSectionsRevealed(_ revealed: Bool) -> Bool {
        guard revealed != isSectionsRevealed else { return false }
        isSectionsRevealed = revealed
        applySectionsVisibility()
        return true
    }

    private func applySectionsVisibility() {
        for view in sections {
            view.isHidden = !isSectionsRevealed
        }
    }

    /// 投稿、フォロー、フォロワーの数。フォローとフォロワーは、数と名前に、押すと開く一覧を付ける。
    static func countsText(of account: Account) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let bold = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
        let text = NSMutableAttributedString()
        let counts: [(Int, String, ProfileCountList?)] = [(account.statusesCount, "投稿", nil), (account.followingCount, "フォロー", .following), (account.followersCount, "フォロワー", .followers)]
        for (index, (count, label, list)) in counts.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "　", attributes: [.font: font]))
            }
            var countAttributes: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: UIColor.label]
            var labelAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
            if let list {
                countAttributes[.profileCountList] = list.rawValue
                labelAttributes[.profileCountList] = list.rawValue
            }
            text.append(NSAttributedString(string: count.formatted(), attributes: countAttributes))
            text.append(NSAttributedString(string: " \(label)", attributes: labelAttributes))
        }
        return text
    }

    @objc private func countsTapped(_ gesture: UITapGestureRecognizer) {
        guard let index = countsLabel.characterIndex(at: gesture.location(in: countsLabel)),
              let rawValue = countsLabel.attributedText?.attribute(.profileCountList, at: index, effectiveRange: nil) as? String,
              let list = ProfileCountList(rawValue: rawValue)
        else { return }
        onOpenCountList?(list)
    }

    /// 固定された投稿の棚と、その下を、一覧の行と一緒にフェードで出す。
    func fadeInSections(duration: TimeInterval) {
        guard duration > 0 else { return }
        for shelf in [pinnedShelf] + sections where !shelf.isHidden {
            shelf.alpha = 0
            UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction]) {
                shelf.alpha = 1
            }
        }
    }

    /// ウィンドウの座標で渡した帯（ステータスバー）の下に見えるヘッダー画像やそのぼかしに、読みやすい文字の色。
    /// バーの下まで伸ばしていないか、画面に出ていなければnil。
    func textTone(under band: CGRect) -> StatusBarTextTone? {
        guard hasBannerImage, let bannerLuminance, let window, !band.isEmpty else { return nil }
        let bannerTop = bannerView.convert(CGPoint.zero, to: window).y
        return bannerLuminance.luminance(
            underBandFrom: band.minY - bannerTop,
            to: band.maxY - bannerTop,
            bannerHeight: bannerView.bounds.height
        ).map(StatusBarTextTone.init(backgroundLuminance:))
    }

    /// Mastodonが、ヘッダー画像を設定していないアカウントに返す1×1の透明な画像ではない。
    private static func isRealBanner(_ image: UIImage) -> Bool {
        image.size.width * image.scale > 1 || image.size.height * image.scale > 1
    }
}

/// ヘッダー画像。タップすると、ビューアで大きく見る。
private final class ProfileBannerView: UIImageView, MediaViewerSource {
    var overlappingViews: [UIView] = []
    /// ビューアが画像を動かしている間、ヘッダー画像に重ねて隠すビュー。
    /// ヘッダー画像そのものを隠すと、上へ伸ばしたぼかしも消え、隠すのをやめてからも数コマ遅れて出るため、画像は隠さずに上に重ねる。
    weak var cover: UIView?
    /// 隠すビューを出したり外したりしたときに呼ぶ。
    var onChangeConcealment: (() -> Void)?

    var isConcealedForViewer: Bool {
        get { cover?.isHidden == false }
        set {
            guard newValue != isConcealedForViewer else { return }
            cover?.isHidden = !newValue
            onChangeConcealment?()
        }
    }
}

/// 背景色の内側に余白を取るラベル。
private final class PaddedLabel: UILabel {
    /// 添付ファイルのバッジ（`MediaBadgeView`）と同じ余白。
    private let insets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

/// プロフィールの数から開く人の一覧。
enum ProfileCountList: String, CaseIterable {
    case following
    case followers

    var accessibilityName: String {
        switch self {
        case .following: "フォローしている人の一覧"
        case .followers: "フォロワーの一覧"
        }
    }
}

extension NSAttributedString.Key {
    /// プロフィールの数の文字で、押すと開く人の一覧（`ProfileCountList`の`rawValue`）。
    static let profileCountList = NSAttributedString.Key("net.mizle.scia.profileCountList")
}
