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
        let tab: ProfileTab
        let postsFilter: ProfilePostsFilter
        let avatarShape: AvatarShape
        let animatesAvatar: Bool
        /// 自分のサーバーのアカウントではない。投稿や数が実際と合わないことを知らせる。
        let isRemote: Bool
    }

    var onToggleFollow: ((UIView) -> Void)?
    /// フォローの関係を読めなかったときに、フォローのボタンの場所に出す再試行が押された。
    var onRetryRelationship: (() -> Void)?
    var onSelectTab: ((ProfileTab) -> Void)?
    var onChangePostsFilter: ((ProfilePostsFilter) -> Void)?
    var onOpenOriginal: (() -> Void)?
    /// アイコンかヘッダー画像がタップされた。画像を読み込み終えていなければ呼ばない。
    var onOpenImage: ((ProfileImage) -> Void)?

    /// ヘッダー画像の縦横比（高さ÷幅）。Mastodonのヘッダー画像は3:1を想定している。
    private static let bannerAspect: CGFloat = 1 / 3
    private static let avatarSize: CGFloat = 80
    private static let avatarRing: CGFloat = 3

    private let emojiImages: EmojiImageStore
    private let mediaImages: MediaImageStore
    private let bannerView = ProfileBannerView()
    private let avatarRingView = UIView()
    private let avatarView: AvatarView
    private let followButton = UIButton(configuration: .filled())
    private let relationshipFailureStack = UIStackView()
    private let relationshipRetryButton = UIButton(configuration: .plain())
    private let nameLabel = UILabel()
    private let acctLabel = UILabel()
    private let followedByLabel = PaddedLabel()
    private let noteLabel = UILabel()
    private let fieldsStack = UIStackView()
    private let countsLabel = UILabel()
    private let remoteStack = UIStackView()
    private let openOriginalButton = UIButton(configuration: .plain())
    private let tabControl = UISegmentedControl(items: ["投稿", "メディア"])
    private let filterButton = UIButton(configuration: .plain())
    private var content: Content?
    private var bannerTask: Task<Void, Never>?
    private var bannerURL: URL?

    init(emojiImages: EmojiImageStore, mediaImages: MediaImageStore, avatarImages: AvatarImageStore) {
        self.emojiImages = emojiImages
        self.mediaImages = mediaImages
        avatarView = AvatarView(store: avatarImages)
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        bannerView.contentMode = .scaleAspectFill
        bannerView.clipsToBounds = true
        bannerView.backgroundColor = .secondarySystemFill

        bannerView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openHeader)))
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openAvatar)))
        for (view, label) in [(bannerView, "ヘッダー画像"), (avatarView, "アイコン")] as [(UIImageView, String)] {
            view.isUserInteractionEnabled = true
            view.isAccessibilityElement = true
            view.accessibilityLabel = label
            view.accessibilityTraits = [.image, .button]
        }

        // アイコンはヘッダー画像に半分かかるため、ヘッダー画像を開閉する間もアイコンを手前に見せる。
        bannerView.overlappingViews = [avatarRingView, avatarView]

        avatarRingView.backgroundColor = .systemBackground
        avatarRingView.layer.cornerCurve = .continuous

        followButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onToggleFollow?(self.followButton)
        }, for: .primaryActionTriggered)
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // フォローの関係を読めなかったら、ボタンを黙って消さず、その場所で読めなかったことと再試行を示す。
        let relationshipFailureLabel = UILabel()
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
        relationshipFailureStack.alignment = .center
        relationshipFailureStack.spacing = 0
        relationshipFailureStack.addArrangedSubview(relationshipFailureLabel)
        relationshipFailureStack.addArrangedSubview(relationshipRetryButton)
        let followArea = UIStackView(arrangedSubviews: [relationshipFailureStack, followButton])
        followArea.axis = .horizontal
        followArea.alignment = .center

        nameLabel.numberOfLines = 0
        acctLabel.numberOfLines = 0
        followedByLabel.font = .preferredFont(forTextStyle: .caption1)
        followedByLabel.textColor = .secondaryLabel
        followedByLabel.backgroundColor = .secondarySystemFill
        followedByLabel.layer.cornerRadius = 4
        followedByLabel.clipsToBounds = true
        followedByLabel.text = "フォローされています"
        noteLabel.numberOfLines = 0
        fieldsStack.axis = .vertical
        fieldsStack.spacing = 8
        countsLabel.numberOfLines = 0

        let remoteLabel = UILabel()
        remoteLabel.numberOfLines = 0
        remoteLabel.font = .preferredFont(forTextStyle: .footnote)
        remoteLabel.textColor = .secondaryLabel
        remoteLabel.text = "他のサーバーのアカウントです。投稿は、このサーバーが受け取ったものだけを表示しています。"
        let openOriginal = openOriginalButton
        openOriginal.configuration?.title = "元のサーバーで開く"
        openOriginal.configuration?.image = UIImage(systemName: "safari")
        openOriginal.configuration?.imagePadding = 4
        openOriginal.configuration?.contentInsets = .zero
        openOriginal.contentHorizontalAlignment = .leading
        openOriginal.addAction(UIAction { [weak self] _ in self?.onOpenOriginal?() }, for: .primaryActionTriggered)
        remoteStack.axis = .vertical
        remoteStack.alignment = .leading
        remoteStack.spacing = 4
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

        let followedByRow = UIStackView(arrangedSubviews: [followedByLabel, UIView()])
        let infoStack = UIStackView(arrangedSubviews: [nameLabel, acctLabel, followedByRow, noteLabel, fieldsStack, countsLabel, remoteStack, tabRow])
        infoStack.axis = .vertical
        infoStack.spacing = 8
        infoStack.setCustomSpacing(2, after: nameLabel)
        infoStack.setCustomSpacing(12, after: remoteStack)
        infoStack.setCustomSpacing(12, after: countsLabel)

        for view in [bannerView, avatarRingView, avatarView, followArea, infoStack] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let margin: CGFloat = 16
        NSLayoutConstraint.activate([
            bannerView.topAnchor.constraint(equalTo: topAnchor),
            bannerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bannerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerView.heightAnchor.constraint(equalTo: bannerView.widthAnchor, multiplier: Self.bannerAspect),

            // アイコンはヘッダー画像の下端に半分かける。
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin + Self.avatarRing),
            avatarView.centerYAnchor.constraint(equalTo: bannerView.bottomAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarRingView.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarRingView.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            avatarRingView.widthAnchor.constraint(equalTo: avatarView.widthAnchor, constant: Self.avatarRing * 2),
            avatarRingView.heightAnchor.constraint(equalTo: avatarView.heightAnchor, constant: Self.avatarRing * 2),

            followArea.topAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: 12),
            followArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            followArea.leadingAnchor.constraint(greaterThanOrEqualTo: avatarRingView.trailingAnchor, constant: 12),

            infoStack.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 12),
            infoStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            infoStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            infoStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @objc private func openAvatar() {
        open(.avatar)
    }

    @objc private func openHeader() {
        open(.header)
    }

    private func open(_ image: ProfileImage) {
        guard viewerSource(for: image) != nil else { return }
        onOpenImage?(image)
    }

    /// ビューアを開閉する起点。画像を読み込み終えていなければ、大きくして見るものがないのでnil。
    /// Mastodonは、ヘッダー画像を設定していないアカウントに1×1の透明な画像（`/headers/original/missing.png`）を返すため、それも開かない。
    func viewerSource(for image: ProfileImage) -> (any MediaViewerSource)? {
        let view: any UIImageView & MediaViewerSource = switch image {
        case .avatar: avatarView
        case .header: bannerView
        }
        guard let shown = view.image, window != nil else { return nil }
        let pixels = CGSize(width: shown.size.width * shown.scale, height: shown.size.height * shown.scale)
        guard pixels.width > 1 || pixels.height > 1 else { return nil }
        return view
    }

    func apply(_ content: Content) {
        self.content = content
        let account = content.account

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
        nameLabel.attributedText = RichTextRenderer(font: boldTitle, textColor: .label, emojiImages: emojiImages)
            .render(.plain(account.displayNameOrUsername, emojis: account.emojis))
        acctLabel.attributedText = acctText(of: account)
        followedByLabel.superview?.isHidden = !content.followedBy || content.followState == .myself

        let body = UIFont.preferredFont(forTextStyle: .body)
        let note = RichTextRenderer(font: body, textColor: .label, paragraphSpacing: 6, emojiImages: emojiImages).render(.html(account.note, emojis: account.emojis))
        noteLabel.attributedText = note
        noteLabel.isHidden = note.length == 0
        applyFields(account)
        countsLabel.attributedText = countsText(of: account)
        remoteStack.isHidden = !content.isRemote
        // サーバーがプロフィールのURLを返さなかったら、開く先がないのでボタンを出さない。
        openOriginalButton.isHidden = account.url == nil

        applyFollowButton(content)
        tabControl.selectedSegmentIndex = content.tab == .media ? 1 : 0
        // メディアの一覧では使えないが、消すとタブの幅が変わって動くため、場所を残したまま押せなくする。
        filterButton.isEnabled = content.tab == .posts
        applyFilterButton(content.postsFilter)
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

    private func applyFields(_ account: Account) {
        fieldsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fieldsStack.isHidden = account.fields.isEmpty
        let nameFont = UIFont.preferredFont(forTextStyle: .footnote)
        let valueFont = UIFont.preferredFont(forTextStyle: .subheadline)
        for field in account.fields {
            let nameLabel = UILabel()
            nameLabel.numberOfLines = 0
            nameLabel.attributedText = RichTextRenderer(font: nameFont, textColor: .secondaryLabel, emojiImages: emojiImages)
                .render(.plain(field.name, emojis: account.emojis))
            let valueLabel = UILabel()
            valueLabel.numberOfLines = 0
            let value = NSMutableAttributedString(attributedString: RichTextRenderer(font: valueFont, textColor: .label, emojiImages: emojiImages)
                .render(.html(field.value, emojis: account.emojis)))
            if field.verifiedAt != nil,
               let check = UIImage(systemName: "checkmark.seal.fill", withConfiguration: UIImage.SymbolConfiguration(font: valueFont, scale: .small)) {
                // リンク先にこのアカウントへのリンクがあると確かめられた値に付く印。
                value.append(NSAttributedString(string: " "))
                value.append(NSAttributedString(attachment: NSTextAttachment(image: check.withTintColor(.systemGreen, renderingMode: .alwaysOriginal))))
                valueLabel.accessibilityValue = "確認済み"
            }
            valueLabel.attributedText = value
            let row = UIStackView(arrangedSubviews: [nameLabel, valueLabel])
            row.axis = .vertical
            row.spacing = 2
            fieldsStack.addArrangedSubview(row)
        }
    }

    private func countsText(of account: Account) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let bold = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
        let text = NSMutableAttributedString()
        for (index, (count, label)) in [(account.statusesCount, "投稿"), (account.followingCount, "フォロー"), (account.followersCount, "フォロワー")].enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "　", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: count.formatted(), attributes: [.font: bold, .foregroundColor: UIColor.label]))
            text.append(NSAttributedString(string: " \(label)", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        }
        return text
    }

    private func applyFollowButton(_ content: Content) {
        let title: String?
        var configuration: UIButton.Configuration
        switch content.followState {
        case .myself, .unknown, .loadFailed, .blocked:
            title = nil
            configuration = .filled()
        case .notFollowing(let locked):
            title = locked ? "フォローをリクエスト" : "フォローする"
            configuration = .filled()
        case .requested:
            title = "リクエスト中"
            configuration = .gray()
        case .following:
            title = "フォロー中"
            configuration = .gray()
        }
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.showsActivityIndicator = content.isChangingFollow
        followButton.configuration = configuration
        followButton.isHidden = title == nil
        followButton.isEnabled = !content.isChangingFollow

        relationshipFailureStack.isHidden = content.followState != .loadFailed
        relationshipRetryButton.configuration?.showsActivityIndicator = content.isReloadingRelationship
        relationshipRetryButton.isEnabled = !content.isReloadingRelationship
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
        bannerView.image = nil
        guard let url else { return }
        let pixelSize = Int((max(bounds.width, 402) * traitCollection.displayScale).rounded(.up))
        if let cached = mediaImages.cachedImage(for: url, maxPixelSize: pixelSize) {
            bannerView.image = cached
            return
        }
        bannerTask = Task { [weak self, mediaImages] in
            guard let image = try? await mediaImages.image(for: url, maxPixelSize: pixelSize), let self, !Task.isCancelled, self.bannerURL == url else { return }
            UIView.transition(with: self.bannerView, duration: 0.15, options: .transitionCrossDissolve) {
                self.bannerView.image = image
            }
        }
    }
}

/// ヘッダー画像。タップすると、ビューアで大きく見る。
private final class ProfileBannerView: UIImageView, MediaViewerSource {
    var overlappingViews: [UIView] = []
}

/// 背景色の内側に余白を取るラベル。
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
