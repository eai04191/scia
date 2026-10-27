import SciaCore
import UIKit

/// プロフィールの編集画面の入力欄。補完の候補を出している間は、ハードウェアキーボードで選べる。
@MainActor
protocol ProfileEditInput: UIView, UITextInput {
    var completionKeys: CompletionKeys { get set }
    var inputAccessoryView: UIView? { get set }
}

/// 1行の入力欄。表示名と、補足情報の名前と内容に使う。
final class ProfileEditTextField: GlyphLanguageTextField, ProfileEditInput {
    var completionKeys = CompletionKeys()
    /// 補足情報の行の入力欄なら、その行。
    weak var fieldCell: ProfileEditFieldCell?
    /// 補完する語の種類。
    var completionKinds: Set<CompletionKind> = [.emoji]

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        clearButtonMode = .whileEditing
        returnKeyType = .next
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + completionKeys.commands(move: #selector(moveCompletion(_:)), confirm: #selector(confirmCompletion), dismiss: #selector(dismissCompletion))
    }

    @objc private func moveCompletion(_ command: UIKeyCommand) {
        completionKeys.move(command.input == UIKeyCommand.inputUpArrow ? -1 : 1)
    }

    @objc private func confirmCompletion() {
        completionKeys.confirm()
    }

    @objc private func dismissCompletion() {
        completionKeys.dismiss()
    }
}

/// 自己紹介の入力欄。スクロールせず、本文に合わせて行の高さを伸ばす。
final class ProfileEditTextView: GlyphLanguageTextView, ProfileEditInput {
    var completionKeys = CompletionKeys()
    private let placeholderLabel = UILabel()

    var placeholder: String? {
        get { placeholderLabel.text }
        set { placeholderLabel.text = newValue }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textContainer.lineFragmentPadding = 0
        placeholderLabel.font = font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 文字を外から入れたときは、入力欄の知らせが来ないので、入れたあとに呼ぶ。
    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + completionKeys.commands(move: #selector(moveCompletion(_:)), confirm: #selector(confirmCompletion), dismiss: #selector(dismissCompletion))
    }

    @objc private func moveCompletion(_ command: UIKeyCommand) {
        completionKeys.move(command.input == UIKeyCommand.inputUpArrow ? -1 : 1)
    }

    @objc private func confirmCompletion() {
        completionKeys.confirm()
    }

    @objc private func dismissCompletion() {
        completionKeys.dismiss()
    }
}

/// 入力欄を1つだけ載せる行。行を作り直しても同じ入力欄を載せ直し、書いている文字とフォーカスを保つ。
final class ProfileEditInputCell: UITableViewCell {
    init(input: UIView) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        input.removeFromSuperview()
        input.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(input)
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: input is UITextView ? -8 : 0),
            input.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: input is UITextView ? 8 : 0),
            input.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 補足情報の1行。名前と内容の2つの入力欄を縦に並べる。
final class ProfileEditFieldCell: UITableViewCell, UITextFieldDelegate {
    static let reuseIdentifier = "ProfileEditFieldCell"

    var onChange: (ProfileFieldDraft.ID, String?, String?) -> Void = { _, _, _ in }
    var onTextChange: (any UITextInput) -> Void = { _ in }
    var onSelectionChange: (any UITextInput) -> Void = { _ in }
    var onBeginEditing: (any UITextInput & UIView) -> Void = { _ in }
    var onEndEditing: (any UITextInput) -> Void = { _ in }

    private let nameField = ProfileEditTextField()
    private let valueField = ProfileEditTextField()
    private var fieldID: ProfileFieldDraft.ID?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        nameField.placeholder = "名前"
        nameField.accessibilityLabel = "補足情報の名前"
        nameField.font = .preferredFont(forTextStyle: .subheadline)
        valueField.placeholder = "内容"
        valueField.completionKinds = Set(CompletionKind.allCases)
        valueField.accessibilityLabel = "補足情報の内容"
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        let stack = UIStackView(arrangedSubviews: [nameField, divider, valueField])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        for field in [nameField, valueField] {
            field.fieldCell = self
            field.delegate = self
            field.addAction(UIAction { [weak self, weak field] _ in
                guard let self, let field else { return }
                reportChange(of: field)
                onTextChange(field)
            }, for: .editingChanged)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(field: ProfileFieldDraft, settings: AppSettings, accessory: () -> UIView, keys: CompletionKeys) {
        fieldID = field.id
        nameField.text = field.name
        valueField.text = field.value
        for input in [nameField, valueField] {
            input.followGlyphLanguage(of: settings)
            input.completionKeys = keys
            input.inputAccessoryView = accessory()
        }
    }

    func focusName() {
        nameField.becomeFirstResponder()
    }

    /// 内容の欄にキーボードを出し、その欄を返す。
    @discardableResult
    func focusValue() -> ProfileEditTextField {
        valueField.becomeFirstResponder()
        return valueField
    }

    /// 入力欄の文字を下書きに入れる。
    func reportChange(of field: ProfileEditTextField) {
        guard let fieldID else { return }
        if field === nameField {
            onChange(fieldID, nameField.text ?? "", nil)
        } else {
            onChange(fieldID, nil, valueField.text ?? "")
        }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard let field = textField as? ProfileEditTextField else { return }
        onBeginEditing(field)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onEndEditing(textField)
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        onSelectionChange(textField)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === nameField {
            valueField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return false
    }
}

/// 区切りの下に出す文字数と、問題の文言。右に寄せ、上限を超えたら赤くする。
/// 余白は表が決める`contentView`の余白に合わせる。ただの`UIView`で余白を決めると、表が高さを測るときと置いたときで幅が変わり、折り返した文言が切れた。
final class ProfileEditFooter: UITableViewHeaderFooterView {
    private let label = UILabel()

    init() {
        super.init(reuseIdentifier: nil)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    /// 今の幅で、文字に要る高さ。文字を変えたあとに、表の行の高さを測り直すかを決めるのに使う。
    var fittingHeight: CGFloat {
        let width = label.bounds.width
        guard width > 0 else { return 0 }
        return label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCount(_ count: Int, limit: Int) {
        setText("\(count) / \(limit)", isProblem: count > limit)
    }

    func setText(_ text: String, isProblem: Bool) {
        label.text = text
        label.textColor = isProblem ? .systemRed : .secondaryLabel
        label.font = .monospacedDigitFont(forTextStyle: .footnote)
    }
}

/// ヘッダー画像とアイコンの行。プロフィール画面と同じく、ヘッダー画像の下端にアイコンを重ねる。押すと、選ぶ、削除、取り消しのメニューを出す。
final class ProfileEditImagesCell: UITableViewCell {
    var onPick: (ProfileImage) -> Void = { _ in }
    var onRemove: (ProfileImage) -> Void = { _ in }
    var onRevert: (ProfileImage) -> Void = { _ in }
    /// ヘッダー画像の枠の高さが変わった。表に行の高さを測り直させる。後から届いた画像で変わったときは、`true`を渡す。動きでつなぐため。
    var onHeightChange: (_ animated: Bool) -> Void = { _ in }

    private let headerButton = UIButton(type: .custom)
    private let headerImageView = UIImageView()
    private let avatarButton = UIButton(type: .custom)
    private let avatarImageView = UIImageView()
    private let avatarRing = UIView()
    /// ヘッダー画像の枠の高さ（幅に対する比）。見せている画像の比率に合わせる。
    private var headerHeight: NSLayoutConstraint?
    private var originals: [ProfileImage: UIImage] = [:]
    private var loadTasks: [Task<Void, Never>] = []
    private var avatarShape: AvatarShape = .circle
    private static let avatarSize: CGFloat = 80
    private static let ring: CGFloat = 4

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        backgroundColor = .clear
        backgroundConfiguration = .clear()

        headerImageView.contentMode = .scaleAspectFill
        headerImageView.clipsToBounds = true
        headerImageView.backgroundColor = .tertiarySystemFill
        headerImageView.layer.cornerRadius = 16
        headerImageView.layer.cornerCurve = .continuous
        headerImageView.isUserInteractionEnabled = false
        headerImageView.translatesAutoresizingMaskIntoConstraints = false
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.showsMenuAsPrimaryAction = true
        headerButton.accessibilityLabel = "ヘッダー画像"
        headerButton.addSubview(headerImageView)

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.backgroundColor = .tertiarySystemFill
        avatarImageView.tintColor = .secondaryLabel
        avatarImageView.isUserInteractionEnabled = false
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarRing.backgroundColor = .systemGroupedBackground
        avatarRing.isUserInteractionEnabled = false
        avatarRing.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.showsMenuAsPrimaryAction = true
        avatarButton.accessibilityLabel = "アイコン"
        avatarButton.addSubview(avatarRing)
        avatarButton.addSubview(avatarImageView)

        let headerBadge = Self.makeBadge()
        let avatarBadge = Self.makeBadge()
        headerButton.addSubview(headerBadge)
        avatarButton.addSubview(avatarBadge)
        contentView.addSubview(headerButton)
        contentView.addSubview(avatarButton)

        let size = Self.avatarSize
        let headerHeight = headerButton.heightAnchor.constraint(equalTo: headerButton.widthAnchor, multiplier: Self.headerHeightRatio(of: nil))
        self.headerHeight = headerHeight
        NSLayoutConstraint.activate([
            headerHeight,
            headerButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerImageView.topAnchor.constraint(equalTo: headerButton.topAnchor),
            headerImageView.bottomAnchor.constraint(equalTo: headerButton.bottomAnchor),
            headerImageView.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor),
            headerImageView.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor),
            headerBadge.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor, constant: -10),
            headerBadge.topAnchor.constraint(equalTo: headerButton.topAnchor, constant: 10),

            avatarButton.widthAnchor.constraint(equalToConstant: size + Self.ring * 2),
            avatarButton.heightAnchor.constraint(equalToConstant: size + Self.ring * 2),
            avatarButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16 - Self.ring),
            avatarButton.centerYAnchor.constraint(equalTo: headerButton.bottomAnchor),
            avatarButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            avatarRing.topAnchor.constraint(equalTo: avatarButton.topAnchor),
            avatarRing.bottomAnchor.constraint(equalTo: avatarButton.bottomAnchor),
            avatarRing.leadingAnchor.constraint(equalTo: avatarButton.leadingAnchor),
            avatarRing.trailingAnchor.constraint(equalTo: avatarButton.trailingAnchor),
            avatarImageView.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
            avatarImageView.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: size),
            avatarImageView.heightAnchor.constraint(equalToConstant: size),
            avatarBadge.trailingAnchor.constraint(equalTo: avatarButton.trailingAnchor),
            avatarBadge.bottomAnchor.constraint(equalTo: avatarButton.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// ヘッダー画像の枠の、幅に対する高さ。画像の比率で見せ、3:1より横に長いものと3:2より縦に長いものは、その比率で切って見せる。
    /// 画像がなければ、Sciaが勧める3:2の枠を見せる。
    private static func headerHeightRatio(of image: UIImage?) -> CGFloat {
        let standard = 1 / CGFloat(ProfileImageCrop.HeaderAspect.standard.ratio)
        guard let image, image.size.width > 0 else { return standard }
        let wide = 1 / CGFloat(ProfileImageCrop.HeaderAspect.wide.ratio)
        return min(max(image.size.height / image.size.width, wide), standard)
    }

    /// 押せることを示す、鉛筆のアイコン。
    private static func makeBadge() -> UIView {
        let badge = UIImageView(image: UIImage(systemName: "pencil.circle.fill"))
        badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26).applying(UIImage.SymbolConfiguration(paletteColors: [.white, .tintColor]))
        badge.isUserInteractionEnabled = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        return badge
    }

    /// 今の画像を読み込む。端末に読み込み済みの画像は、すぐ出す。同じ画像で呼び直したときは、読み直さない。
    func apply(account: Account, mediaImages: MediaImageStore, avatarShape: AvatarShape) {
        self.avatarShape = avatarShape
        let scale = max(traitCollection.displayScale, 2)
        let requests = [(ProfileImage.avatar, account.avatarStatic, Int(Self.avatarSize * scale)), (.header, account.headerStatic, Int(402 * scale))]
        let urls = requests.map(\.1)
        guard urls != requestedURLs else {
            refresh()
            return
        }
        requestedURLs = urls
        loadTasks.forEach { $0.cancel() }
        pendingImages = []
        loadTasks = requests.compactMap { kind, url, size in
            guard let url else { return nil }
            if let cached = mediaImages.cachedImage(for: url, maxPixelSize: size) {
                originals[kind] = cached
                return nil
            }
            pendingImages.insert(kind)
            return Task { [weak self] in
                let image = try? await mediaImages.image(for: url, maxPixelSize: size)
                guard let self, !Task.isCancelled else { return }
                self.pendingImages.remove(kind)
                if let image {
                    self.originals[kind] = image
                    self.refresh(fadesImages: true)
                }
                if self.pendingImages.isEmpty {
                    self.finishWaitingForImages()
                }
            }
        }
        refresh()
    }

    /// 読み込んでいる画像が届くのを、`timeout`まで待つ。表を出す前に呼び、出したあとにアイコンが人の記号から1コマで替わるのを避ける。
    func waitForImages(within timeout: Duration, clock: any Clock<Duration>) async {
        guard !pendingImages.isEmpty, timeout > .zero else { return }
        finishWaitingForImages()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            imagesWaiter = continuation
            imagesWaitTimer = Task { [weak self] in
                try? await clock.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finishWaitingForImages()
            }
        }
    }

    private func finishWaitingForImages() {
        imagesWaitTimer?.cancel()
        imagesWaitTimer = nil
        imagesWaiter?.resume()
        imagesWaiter = nil
    }

    /// 後から届いた画像を入れ替えるクロスフェードの時間。0なら切り替える。
    var imageFadeDuration: TimeInterval = 0
    private var requestedURLs: [URL?]?
    /// アイコンに出している画像。人の記号を出しているときはnil。
    private var shownAvatar: UIImage?
    /// まだ届いていない画像。
    private var pendingImages: Set<ProfileImage> = []
    private var imagesWaiter: CheckedContinuation<Void, Never>?
    private var imagesWaitTimer: Task<Void, Never>?

    private var shown: (avatar: ProfileImageChange, header: ProfileImageChange, replaced: [ProfileImage: UIImage], hasAvatar: Bool, hasHeader: Bool)?

    /// 下書きに合わせて、見せる画像とメニューを変える。
    func show(avatar: ProfileImageChange, header: ProfileImageChange, replaced: [ProfileImage: UIImage], hasAvatar: Bool, hasHeader: Bool) {
        shown = (avatar, header, replaced, hasAvatar, hasHeader)
        refresh()
    }

    /// - Parameter fadesImages: 後から届いた画像を、前の見え方からクロスフェードで入れる。ヘッダー画像の枠の高さが変わるときは、表に動きで測り直させる。
    private func refresh(fadesImages: Bool = false) {
        guard let shown else { return }
        let fades = fadesImages && imageFadeDuration > 0 && window != nil
        avatarImageView.layer.cornerRadius = switch avatarShape {
        case .circle: Self.avatarSize / 2
        case .roundedSquare: Self.avatarSize * 0.2
        }
        avatarImageView.layer.cornerCurve = .continuous
        avatarRing.layer.cornerRadius = switch avatarShape {
        case .circle: (Self.avatarSize + Self.ring * 2) / 2
        case .roundedSquare: Self.avatarSize * 0.2 + Self.ring
        }
        avatarRing.layer.cornerCurve = .continuous
        let avatar = image(for: .avatar, change: shown.avatar, replaced: shown.replaced, has: shown.hasAvatar)
        let header = image(for: .header, change: shown.header, replaced: shown.replaced, has: shown.hasHeader)
        // 見え方が変わるビューにだけクロスフェードをかける。アイコンとヘッダー画像はほぼ同時に届くことがあり、
        // 変わらないビューにかけ直すと、進んでいる途中のクロスフェードが新しい画像同士の遷移に置き換わり、1コマで替わって見えるため。
        crossfade(avatarImageView, if: fades && avatar !== shownAvatar) {
            self.avatarImageView.image = avatar ?? UIImage(systemName: "person.fill")
            self.avatarImageView.contentMode = avatar == nil ? .center : .scaleAspectFill
        }
        shownAvatar = avatar
        crossfade(headerImageView, if: fades && header !== headerImageView.image) {
            self.headerImageView.image = header
        }
        let ratio = Self.headerHeightRatio(of: header)
        if let headerHeight, abs(headerHeight.multiplier - ratio) > 0.001 {
            headerHeight.isActive = false
            let replaced = headerButton.heightAnchor.constraint(equalTo: headerButton.widthAnchor, multiplier: ratio)
            replaced.isActive = true
            self.headerHeight = replaced
            onHeightChange(fades)
        }
        avatarButton.menu = menu(for: .avatar, change: shown.avatar, has: shown.hasAvatar)
        headerButton.menu = menu(for: .header, change: shown.header, has: shown.hasHeader)
        avatarButton.accessibilityValue = Self.accessibilityValue(change: shown.avatar, has: shown.hasAvatar)
        headerButton.accessibilityValue = Self.accessibilityValue(change: shown.header, has: shown.hasHeader)
    }

    /// 見え方を変える。`fades`なら、前の見え方からクロスフェードで入れる。変わらなければ、見た目は動かない。
    private func crossfade(_ view: UIImageView, if fades: Bool, _ change: @escaping () -> Void) {
        guard fades else {
            change()
            return
        }
        UIView.transition(with: view, duration: imageFadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: change)
    }

    private func image(for kind: ProfileImage, change: ProfileImageChange, replaced: [ProfileImage: UIImage], has: Bool) -> UIImage? {
        switch change {
        case .keep: has ? originals[kind] : nil
        case .replace: replaced[kind]
        case .remove: nil
        }
    }

    private static func accessibilityValue(change: ProfileImageChange, has: Bool) -> String {
        switch change {
        case .keep: has ? "設定済み" : "未設定"
        case .replace: "変更あり"
        case .remove: "削除予定"
        }
    }

    private func menu(for kind: ProfileImage, change: ProfileImageChange, has: Bool) -> UIMenu {
        var actions: [UIAction] = [
            UIAction(title: "写真を選ぶ", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.onPick(kind) },
        ]
        if change != .keep {
            actions.append(UIAction(title: "変更を取り消す", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.onRevert(kind) })
        }
        let isSet = switch change {
        case .keep: has
        case .replace: true
        case .remove: false
        }
        if isSet {
            actions.append(UIAction(title: "削除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.onRemove(kind) })
        }
        return UIMenu(children: actions)
    }
}
