import Observation
import os
import PhotosUI
import SciaCore
import UIKit
import UniformTypeIdentifiers

/// 自分のプロフィールの編集画面。シートで出す。
///
/// 入力欄、補完、キー操作を持つので、UIKitの表で組む。補足情報の行は、表の編集の状態で消したり並べ替えたりする。
/// 表示名、自己紹介、補足情報では、投稿欄と同じ補完と絵文字のシートでカスタム絵文字を入れられる。自己紹介と補足情報の内容では、サーバーがメンションとハッシュタグもリンクにするので、それも補完する。
@MainActor
final class ProfileEditViewController: UIViewController {
    /// 保存できたら、シートを閉じる前に呼ぶ。
    var onSaved: (ProfileSource) -> Void = { _ in }
    /// 保存や写真の読み込みに失敗したら、アラートの見出しと一緒に呼ぶ。書いたものはそのまま残る。
    var onError: (any Error, String) -> Void = { _, _ in }

    let editor: ProfileEditor
    private let textCompletion: TextInputCompletion
    private let mediaImages: MediaImageStore
    private let settings: AppSettings
    private let tuning: TuningStore
    /// 表を出す前に画像を待つ上限を数える。
    private let clock: any Clock<Duration>
    private let logger = SciaLog.logger(category: "profile")

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let loadingView = UIActivityIndicatorView(style: .medium)
    private let failureView = UIStackView()
    private let failureLabel = UILabel()
    private let completionList = ComposeCompletionList()
    private var completionListTop: NSLayoutConstraint?
    private var completionListHeight: NSLayoutConstraint?
    private var isCompletionListShown = false
    /// 絵文字のシートを出している間、表の下端をシートの上端に留める。
    private var tableAboveSheet: NSLayoutConstraint?

    private let displayNameField = ProfileEditTextField()
    private let noteView = ProfileEditTextView()
    private let lockedSwitch = UISwitch()
    private let botSwitch = UISwitch()
    private let displayNameFooter = ProfileEditFooter()
    private let noteFooter = ProfileEditFooter()
    private let fieldsFooter = ProfileEditFooter()
    private let imagesCell = ProfileEditImagesCell()
    private lazy var displayNameCell = ProfileEditInputCell(input: displayNameField)
    private lazy var noteCell = ProfileEditInputCell(input: noteView)
    /// 選んで切り抜いた画像。保存するまで、元の画像の代わりに見せる。
    private var replacedImages: [ProfileImage: UIImage] = [:]
    /// 最後に書いていた入力欄。絵文字のシートで選んだ絵文字をここに入れ、閉じたらキーボードを戻す。
    private weak var lastFocusedInput: (any UITextInput & UIView)?
    private lazy var emojiPalette: EmojiPaletteView = makeEmojiPalette()
    private var emojiSheet: EmojiPaletteSheet?
    private var paletteRecentKeys: [String] = []
    private var isObservingEmojiPalette = false
    private var lastKeyboardHeight: CGFloat = 0
    private var isConfirmingDiscard = false
    /// 補足情報の区切りに、追加の行を出しているか。表に出している行と食い違わないよう、出し入れしたときだけ変える。
    /// 上限はあとから届いて変わることがあるため、上限から毎回求めない。
    private var showsAddFieldRow = false
    /// 表に下書きを映した。それまでは表に区切りがないので、行を出し入れしない。
    private var isTableLoaded = false
    /// 読み込み中の表示を薄くしながら、表を出している途中。
    private var isRevealingTable = false
    /// 絵文字のシートが閉じ終わったら行う操作。シートを出している間は、編集画面に別の画面を重ねられず、閉じることもできないため。
    private var afterEmojiSheetCloses: (() -> Void)?
    #if DEBUG
    /// `scia-debug://profile-edit?note=`で渡した、読み込んだあとに置き換える自己紹介。
    var debugNote: String?
    /// `scia-debug://profile-edit?field=`で渡した、読み込んだあとに足す補足情報の内容。
    var debugField: String?
    #endif

    private enum Section: Int, CaseIterable {
        case images
        case displayName
        case note
        case fields
        case flags
    }

    init(editor: ProfileEditor, completion: TextInputCompletion, mediaImages: MediaImageStore = AppDependencies.mediaImages, settings: AppSettings = AppDependencies.settings, tuning: TuningStore = AppDependencies.tuning, clock: any Clock<Duration> = AppDependencies.clock) {
        self.editor = editor
        self.clock = clock
        textCompletion = completion
        self.mediaImages = mediaImages
        self.settings = settings
        self.tuning = tuning
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// ナビゲーションの中に入れてシートで出す画面を作る。
    func wrappedInNavigation() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.presentationController?.delegate = self
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = "プロフィールを編集"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        let save = UIBarButtonItem(title: "保存", style: .prominent, target: nil, action: nil)
        save.primaryAction = UIAction(title: "保存") { [weak self] _ in self?.save() }
        navigationItem.rightBarButtonItem = save

        configureTable()
        configureInputs()
        configureStateViews()
        configureCompletion()
        observeEditor()
        AppDependencies.stateDumps.register("profileEdit", owner: self) { $0.stateDump() }
        Task { await load() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = view.keyboardLayoutGuide.layoutFrame.height
        if height > 100 {
            lastKeyboardHeight = height
        }
        layoutCompletionListIfShown()
    }

    private func load() async {
        await editor.load()
        // プロフィールを開くときと同じく、アイコンとヘッダー画像を上限まで待ってから表を出す。表を出したあとに画像が1コマで入らないようにするため。
        if case .loaded(let source) = editor.source {
            imagesCell.apply(account: source.account, mediaImages: mediaImages, avatarShape: settings.avatarShape)
            await imagesCell.waitForImages(within: .seconds(tuning.value(of: TuningCatalog.profileAvatarWait)), clock: clock)
        }
        showDraft()
        #if DEBUG
        // 読み込めなかったときは入れず、再試行で読めたときに入れる。
        guard editor.draft != nil else { return }
        if let debugNote {
            self.debugNote = nil
            noteView.text = debugNote
            noteView.updatePlaceholder()
            editor.draft?.note = debugNote
            noteView.becomeFirstResponder()
            // 打ったときと同じく、カーソルの位置の語を補完に渡す。
            textCompletion.textDidChange(in: noteView)
        }
        if let debugField, canAddField {
            self.debugField = nil
            editor.draft?.fields.append(ProfileFieldDraft(name: "", value: debugField))
            showDraft()
            let row = (editor.draft?.fields.count ?? 1) - 1
            let path = IndexPath(row: row, section: Section.fields.rawValue)
            tableView.scrollToRow(at: path, at: .middle, animated: false)
            if let input = (tableView.cellForRow(at: path) as? ProfileEditFieldCell)?.focusValue() {
                textCompletion.textDidChange(in: input)
            }
        }
        #endif
    }

    /// 下書きを入力欄と表に映す。読み込んだあとと、カタログで下書きを外から変えたあとに呼ぶ。
    func showDraft() {
        guard let draft = editor.draft else { return }
        displayNameField.text = draft.displayName
        noteView.text = draft.note
        noteView.updatePlaceholder()
        lockedSwitch.isOn = draft.locked
        botSwitch.isOn = draft.bot
        if case .loaded(let source) = editor.source {
            imagesCell.apply(account: source.account, mediaImages: mediaImages, avatarShape: settings.avatarShape)
        }
        updateImages()
        showsAddFieldRow = canAddField
        isTableLoaded = true
        updateFooters()
        tableView.reloadData()
        applyEditorState()
    }

    func stateDump() -> String {
        let source = switch editor.source {
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed(let error): "failed(\(ErrorPresentation(error).code ?? "unknown"))"
        }
        let draft = editor.draft
        return """
        source: \(source) saving: \(editor.isSaving) hasChanges: \(editor.hasChanges) canSave: \(editor.canSave) problems: \(editor.problems.count)
        fields: \(draft?.fields.count ?? 0) avatar: \(Self.describe(draft?.avatar)) header: \(Self.describe(draft?.header))
        completion: input=\(textCompletion.input.map { String(describing: type(of: $0)) } ?? "none") content=\(textCompletion.contentSummary) shown=\(isCompletionListShown)
        emojiSheet: \(emojiSheet != nil)
        """
    }

    private static func describe(_ change: ProfileImageChange?) -> String {
        switch change {
        case nil: "nil"
        case .keep: "keep"
        case .replace(let upload): "replace(\(upload.mimeType), \(upload.data.count)bytes)"
        case .remove: "remove"
        }
    }

    // MARK: - 状態の反映

    private func observeEditor() {
        withObservationTracking {
            applyEditorState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeEditor() }
        }
    }

    private func applyEditorState() {
        // 下書きを読み終えても、表に映すまでは読み込み中の表示を続ける。画像を待つ間に、空の表を出さないため。
        let isLoaded = editor.draft != nil && isTableLoaded
        if tableView.isHidden, isLoaded {
            revealTable()
        }
        tableView.isHidden = !isLoaded
        switch editor.source {
        case .loading where !isLoaded:
            loadingView.startAnimating()
            failureView.isHidden = true
        case .failed(let error) where !isLoaded:
            loadingView.stopAnimating()
            failureLabel.text = "プロフィールを読み込めませんでした\n\(ErrorPresentation(error).text)"
            failureView.isHidden = false
        default:
            if !isLoaded {
                loadingView.startAnimating()
            } else if loadingView.isAnimating, !isRevealingTable {
                loadingView.stopAnimating()
            }
            failureView.isHidden = true
        }
        let saving = editor.isSaving
        navigationItem.rightBarButtonItem?.isEnabled = editor.canSave
        navigationItem.leftBarButtonItem?.isEnabled = !saving
        tableView.isUserInteractionEnabled = !saving
        // 保存している間は、ボタンの場所にインジケーターを出す。
        if saving, !(navigationItem.rightBarButtonItem?.customView is UIActivityIndicatorView) {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            navigationItem.rightBarButtonItem?.customView = indicator
        } else if !saving {
            navigationItem.rightBarButtonItem?.customView = nil
        }
        isModalInPresentation = editor.hasChanges || saving
        syncAddFieldRow()
        updateFooters()
    }

    /// 読み込み中の表示を薄くしながら、表を浮かび上がらせる。
    private func revealTable() {
        let duration = tuning.value(of: TuningCatalog.profileRevealDuration)
        guard duration > 0, view.window != nil else { return }
        isRevealingTable = true
        tableView.alpha = 0
        UIView.animateSmoothly(duration: duration * 0.6) {
            self.loadingView.alpha = 0
        } completion: {
            self.isRevealingTable = false
            self.loadingView.stopAnimating()
            self.loadingView.alpha = 1
        }
        UIView.animateSmoothly(duration: duration) {
            self.tableView.alpha = 1
        }
    }

    /// 文字数や問題の文言を変える。行数が変わったら、表を作り直さずに高さを測り直す。
    private func updateFooters() {
        guard let draft = editor.draft else { return }
        let footers = [displayNameFooter, noteFooter, fieldsFooter]
        let heights = footers.map(\.fittingHeight)
        defer {
            if isTableLoaded, footers.map(\.fittingHeight) != heights {
                UIView.performWithoutAnimation {
                    tableView.performBatchUpdates(nil)
                }
            }
        }
        let limits = editor.limits
        let problems = editor.problems
        displayNameFooter.setCount(draft.displayNameLength, limit: limits.displayName)
        noteFooter.setCount(draft.noteLength(charactersReservedPerURL: editor.charactersReservedPerURL), limit: limits.note)
        let fieldCount = draft.fields.count
        var fieldsText = "\(fieldCount) / \(limits.fields)"
        if problems.contains(where: { if case .fieldNameMissing = $0 { true } else { false } }) {
            fieldsText = "値を書いた行には名前も書いてください"
        } else if problems.contains(where: {
            switch $0 {
            case .fieldNameTooLong, .fieldValueTooLong: true
            default: false
            }
        }) {
            fieldsText = "名前と内容は\(limits.fieldName)文字までです"
        }
        fieldsFooter.setText(fieldsText, isProblem: fieldsText != "\(fieldCount) / \(limits.fields)" || fieldCount > limits.fields)
    }

    // MARK: - 保存と取りやめ

    private func save() {
        guard closeEmojiSheet(then: { [weak self] in self?.save() }) else { return }
        view.endEditing(true)
        Task {
            do {
                let saved = try await editor.save()
                logger.info("profile saved")
                onSaved(saved)
                dismiss(animated: true)
            } catch {
                logger.error("profile save failed: \(SciaLog.describe(error), privacy: .public)")
                onError(error, "プロフィールを保存できませんでした")
            }
        }
    }

    private func cancel() {
        guard closeEmojiSheet(then: { [weak self] in self?.cancel() }) else { return }
        guard editor.hasChanges else {
            dismiss(animated: true)
            return
        }
        confirmDiscard()
    }

    /// 変えたものがあれば、捨ててよいか確かめる。
    private func confirmDiscard() {
        guard !isConfirmingDiscard, !editor.isSaving else { return }
        isConfirmingDiscard = true
        view.endEditing(true)
        let sheet = UIAlertController(title: nil, message: "変更を保存していません", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "変更を破棄", style: .destructive) { [weak self] _ in
            self?.isConfirmingDiscard = false
            self?.dismiss(animated: true)
        })
        sheet.addAction(UIAlertAction(title: "編集を続ける", style: .cancel) { [weak self] _ in
            self?.isConfirmingDiscard = false
        })
        sheet.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(sheet, animated: true)
    }

    // MARK: - 部品

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = true
        tableView.keyboardDismissMode = .interactive
        tableView.register(ProfileEditFieldCell.self, forCellReuseIdentifier: ProfileEditFieldCell.reuseIdentifier)
        view.addSubview(tableView)
        let followsKeyboard = tableView.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor)
        let fillsBottom = tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        fillsBottom.priority = .defaultHigh
        let aboveSheet = tableView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            followsKeyboard,
            fillsBottom,
        ])
        tableAboveSheet = aboveSheet
    }

    private func configureInputs() {
        displayNameField.placeholder = "表示名"
        displayNameField.accessibilityLabel = "表示名"
        displayNameField.followGlyphLanguage(of: settings)
        displayNameField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            editor.draft?.displayName = displayNameField.text ?? ""
            textCompletion.textDidChange(in: displayNameField)
        }, for: .editingChanged)
        noteView.accessibilityLabel = "自己紹介"
        noteView.placeholder = "自己紹介"
        noteView.followGlyphLanguage(of: settings)
        for input in [displayNameField as any ProfileEditInput, noteView] {
            input.completionKeys = textCompletion.keys(
                isShown: { [weak self] in self?.isCompletionListShown == true },
                growsUpward: { [weak self] in self?.completionList.growsUpward == true }
            )
            input.inputAccessoryView = makeInputAccessory()
        }
        displayNameField.delegate = self
        noteView.delegate = self
        lockedSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            editor.draft?.locked = lockedSwitch.isOn
        }, for: .valueChanged)
        botSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            editor.draft?.bot = botSwitch.isOn
        }, for: .valueChanged)
        imagesCell.imageFadeDuration = tuning.value(of: TuningCatalog.profileRevealDuration)
        imagesCell.onHeightChange = { [weak self] animated in
            guard let self, isTableLoaded else { return }
            // 待つ上限を過ぎて届いたヘッダー画像で枠の高さが変わったときは、下の欄ごと動かす。
            if animated, !UIAccessibility.isReduceMotionEnabled {
                UIView.animateSmoothly(duration: self.imagesCell.imageFadeDuration) {
                    self.tableView.performBatchUpdates(nil)
                    self.tableView.layoutIfNeeded()
                }
            } else {
                UIView.performWithoutAnimation {
                    self.tableView.performBatchUpdates(nil)
                }
            }
        }
        imagesCell.onPick = { [weak self] image in self?.pickImage(image) }
        imagesCell.onRemove = { [weak self] image in self?.setImage(image, .remove) }
        imagesCell.onRevert = { [weak self] image in self?.setImage(image, .keep) }
    }

    private func configureStateViews() {
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.hidesWhenStopped = true
        view.addSubview(loadingView)
        failureLabel.numberOfLines = 0
        failureLabel.textAlignment = .center
        failureLabel.font = .preferredFont(forTextStyle: .body)
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.textColor = .secondaryLabel
        var retry = UIButton.Configuration.gray()
        retry.title = "再試行"
        retry.cornerStyle = .capsule
        let retryButton = UIButton(configuration: retry, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Task { await self.load() }
        })
        failureView.axis = .vertical
        failureView.alignment = .center
        failureView.spacing = 12
        failureView.addArrangedSubview(failureLabel)
        failureView.addArrangedSubview(retryButton)
        failureView.translatesAutoresizingMaskIntoConstraints = false
        failureView.isHidden = true
        view.addSubview(failureView)
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            failureView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            failureView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            failureView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])
    }

    /// キーボードの上に、絵文字のシートを開くボタンを置く。
    private func makeInputAccessory() -> UIView {
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let emoji = UIBarButtonItem(image: UIImage(systemName: "face.smiling"), primaryAction: UIAction { [weak self] _ in self?.presentEmojiPalette() })
        emoji.accessibilityLabel = "カスタム絵文字"
        toolbar.items = [emoji, .flexibleSpace()]
        toolbar.sizeToFit()
        return toolbar
    }

    // MARK: - 画像

    private func pickImage(_ image: ProfileImage) {
        guard closeEmojiSheet(then: { [weak self] in self?.pickImage(image) }) else { return }
        view.endEditing(true)
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        pickingImage = image
        present(picker, animated: true)
    }

    private var pickingImage: ProfileImage?

    private func presentCrop(_ cgImage: CGImage, for image: ProfileImage) {
        let crop = ProfileImageCropViewController(image: cgImage, kind: image, avatarShape: settings.avatarShape)
        let navigation = UINavigationController(rootViewController: crop)
        navigation.modalPresentationStyle = .fullScreen
        // 画像を見やすいよう黒地にし、バーの文字とボタンも暗い見た目にそろえる。
        navigation.overrideUserInterfaceStyle = .dark
        crop.onCancel = { [weak navigation] in navigation?.dismiss(animated: true) }
        crop.onDone = { [weak self, weak navigation] upload, preview in
            self?.replaceImage(image, upload: upload, preview: preview)
            navigation?.dismiss(animated: true)
        }
        present(navigation, animated: true)
    }

    /// 切り抜いた画像に替える。保存するまで、元の画像の代わりに`preview`を見せる。
    func replaceImage(_ image: ProfileImage, upload: MediaUpload, preview: UIImage) {
        replacedImages[image] = preview
        setImage(image, .replace(upload))
    }

    private func setImage(_ image: ProfileImage, _ change: ProfileImageChange) {
        switch image {
        case .avatar: editor.draft?.avatar = change
        case .header: editor.draft?.header = change
        }
        if case .replace = change {} else {
            replacedImages[image] = nil
        }
        updateImages()
    }

    private func updateImages() {
        guard let draft = editor.draft, case .loaded(let source) = editor.source else { return }
        imagesCell.show(
            avatar: draft.avatar,
            header: draft.header,
            replaced: replacedImages,
            hasAvatar: source.hasAvatar,
            hasHeader: source.hasHeader
        )
    }

    // MARK: - 補足情報

    private var canAddField: Bool {
        (editor.draft?.fields.count ?? 0) < editor.limits.fields
    }

    private func fieldRowCount() -> Int {
        (editor.draft?.fields.count ?? 0) + (showsAddFieldRow ? 1 : 0)
    }

    private func addField() {
        guard canAddField else { return }
        let index = editor.draft?.fields.count ?? 0
        let section = Section.fields.rawValue
        tableView.performBatchUpdates {
            editor.draft?.fields.append(ProfileFieldDraft())
            tableView.insertRows(at: [IndexPath(row: index, section: section)], with: .automatic)
            // 上限に届いたら、追加の行を消す。消すのは足す前の位置の行。
            if showsAddFieldRow, !canAddField {
                showsAddFieldRow = false
                tableView.deleteRows(at: [IndexPath(row: index, section: section)], with: .automatic)
            }
        } completion: { [weak self] _ in
            (self?.tableView.cellForRow(at: IndexPath(row: index, section: section)) as? ProfileEditFieldCell)?.focusName()
        }
    }

    private func removeField(at row: Int) {
        guard let field = editor.draft?.fields[safe: row] else { return }
        let section = Section.fields.rawValue
        tableView.performBatchUpdates {
            editor.draft?.fields.removeAll { $0.id == field.id }
            tableView.deleteRows(at: [IndexPath(row: row, section: section)], with: .automatic)
            if !showsAddFieldRow, canAddField {
                showsAddFieldRow = true
                tableView.insertRows(at: [IndexPath(row: editor.draft?.fields.count ?? 0, section: section)], with: .automatic)
            }
        }
    }

    /// 上限があとから届いて、追加の行を出すかどうかが変わったら、表の行も出し入れする。
    private func syncAddFieldRow() {
        guard isTableLoaded, showsAddFieldRow != canAddField else { return }
        let path = IndexPath(row: editor.draft?.fields.count ?? 0, section: Section.fields.rawValue)
        showsAddFieldRow = canAddField
        if showsAddFieldRow {
            tableView.insertRows(at: [path], with: .automatic)
        } else {
            tableView.deleteRows(at: [path], with: .automatic)
        }
    }

    private func updateField(_ id: ProfileFieldDraft.ID, name: String? = nil, value: String? = nil) {
        guard let index = editor.draft?.fields.firstIndex(where: { $0.id == id }) else { return }
        if let name { editor.draft?.fields[index].name = name }
        if let value { editor.draft?.fields[index].value = value }
    }

    // MARK: - 補完

    private func configureCompletion() {
        textCompletion.kinds = { [weak self] input in
            // サーバーは自己紹介と補足情報の内容を同じ整形にかけ、メンションとハッシュタグもリンクにする（`FormattingHelper#account_field_value_format`）。
            // 表示名と補足情報の名前は、カスタム絵文字だけを読む。
            if input === self?.noteView { return Set(CompletionKind.allCases) }
            return (input as? ProfileEditTextField)?.completionKinds ?? [.emoji]
        }
        textCompletion.isLocked = { [weak self] in self?.editor.isSaving ?? true }
        textCompletion.onApply = { [weak self] input in self?.inputDidChange(input) }
        completionList.translatesAutoresizingMaskIntoConstraints = false
        completionList.alpha = 0
        completionList.isHidden = true
        completionList.onSelect = { [weak self] candidate in self?.textCompletion.complete(with: candidate) }
        completionList.onRetry = { [weak self] in self?.textCompletion.completion.retry() }
        view.addSubview(completionList)
        let top = completionList.topAnchor.constraint(equalTo: view.topAnchor)
        let height = completionList.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            completionList.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            completionList.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            top,
            height,
        ])
        completionListTop = top
        completionListHeight = height
        observeCompletion()
    }

    private func observeCompletion() {
        withObservationTracking {
            updateCompletionList()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCompletion() }
        }
    }

    private func updateCompletionList() {
        let completion = textCompletion.completion
        let content = completion.content
        if let content, let kind = completion.token?.kind {
            completionList.update(content, kind: kind, selectedIndex: completion.selectedIndex)
        }
        let shows = content != nil && (textCompletion.input as? UIResponder)?.isFirstResponder == true
        if shows {
            layoutCompletionList()
        }
        setCompletionListShown(shows)
    }

    private func layoutCompletionListIfShown() {
        guard isCompletionListShown else { return }
        layoutCompletionList()
    }

    /// 打っている行のすぐ下に置く。キーボードまでに入りきらなければ、行の上の広い方に置き、入りきらない分は一覧の中でスクロールする。
    private func layoutCompletionList() {
        guard let completionListTop, let completionListHeight, let caret = textCompletion.caretRect(in: view) else { return }
        let spacing: CGFloat = 6
        let wanted = completionList.contentHeight
        let lower = view.keyboardLayoutGuide.layoutFrame.minY - spacing
        let upper = view.safeAreaLayoutGuide.layoutFrame.minY + spacing
        let below = lower - (caret.maxY + spacing)
        let above = caret.minY - spacing - upper
        let height: CGFloat
        let top: CGFloat
        if below >= wanted || (above < wanted && below >= above) {
            height = min(wanted, max(below, 0))
            top = caret.maxY + spacing
            completionList.growsUpward = false
        } else {
            height = min(wanted, max(above, 0))
            top = caret.minY - spacing - height
            completionList.growsUpward = true
        }
        if abs(completionListTop.constant - top) > 0.5 { completionListTop.constant = top }
        if abs(completionListHeight.constant - height) > 0.5 { completionListHeight.constant = height }
    }

    private func setCompletionListShown(_ shown: Bool) {
        guard shown != isCompletionListShown else { return }
        isCompletionListShown = shown
        let duration = tuning.value(of: TuningCatalog.completionFadeDuration)
        if shown {
            completionList.isHidden = false
            view.layoutIfNeeded()
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.completionList.alpha = shown ? 1 : 0
        } completion: { _ in
            guard !self.isCompletionListShown else { return }
            self.completionList.isHidden = true
        }
    }

    /// 入力欄の文字を下書きに入れる。補完やパレットで入れたときは、入力欄の知らせが来ないため、ここで合わせる。
    private func inputDidChange(_ input: any UITextInput) {
        if input === displayNameField {
            editor.draft?.displayName = displayNameField.text ?? ""
        } else if input === noteView {
            editor.draft?.note = noteView.text
            noteView.updatePlaceholder()
            noteDidChangeHeight()
        } else if let field = input as? ProfileEditTextField, let cell = field.fieldCell {
            cell.reportChange(of: field)
        }
    }

    /// 自己紹介の行の高さを本文に合わせる。行を作り直さずに測り直し、書いている入力欄のフォーカスを保つ。
    private func noteDidChangeHeight() {
        let height = noteView.sizeThatFits(CGSize(width: noteView.bounds.width, height: .greatestFiniteMagnitude)).height
        guard abs(height - noteView.bounds.height) > 0.5 else { return }
        UIView.performWithoutAnimation {
            tableView.performBatchUpdates(nil)
        }
        scrollToCaret()
    }

    private func scrollToCaret() {
        guard let input = lastFocusedInput, let range = input.selectedTextRange else { return }
        let caret = input.caretRect(for: range.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        tableView.scrollRectToVisible(input.convert(caret, to: tableView).insetBy(dx: 0, dy: -12), animated: false)
    }

    fileprivate func inputDidBeginEditing(_ input: any UITextInput & UIView) {
        lastFocusedInput = input
        textCompletion.inputDidBeginEditing(input)
        guard let emojiSheet, !emojiSheet.isClosing else { return }
        emojiSheet.close(notifiesWillClose: false)
    }

    // MARK: - 絵文字のパレット

    private func makeEmojiPalette() -> EmojiPaletteView {
        let palette = EmojiPaletteView(emojiImages: AppDependencies.emojiImages)
        palette.onSelect = { [weak self] emoji in
            guard let self, let input = lastFocusedInput else { return }
            textCompletion.insert(emoji, into: input)
        }
        palette.onDelete = { [weak self] in
            guard let self, let input = lastFocusedInput else { return }
            textCompletion.deleteBackward(in: input)
        }
        palette.onRetry = { [weak self] in self?.textCompletion.completion.loadEmojisIfNeeded() }
        palette.onQueryChange = { [weak self] in self?.updateEmojiPalette() }
        palette.onSearchSubmit = { [weak self] in
            guard let self else { return }
            emojiPalette.clearQuery()
            updateEmojiPalette()
            emojiSheet?.endSearch()
        }
        return palette
    }

    /// キーボードと同じ高さのシートを出し、表の下端をシートの上端に留めて、書いている行を見せたままにする。
    private func presentEmojiPalette() {
        guard emojiSheet == nil, let input = lastFocusedInput else { return }
        let height = max(lastKeyboardHeight, 300)
        paletteRecentKeys = textCompletion.recentKeys
        textCompletion.completion.loadEmojisIfNeeded()
        emojiPalette.clearQuery()
        updateEmojiPalette()
        observeEmojiPalette()
        tableAboveSheet?.constant = -height
        tableAboveSheet?.isActive = true
        // 独自の高さはシートの下の安全領域を含まないので、その分を引く。
        let sheet = EmojiPaletteSheet(palette: emojiPalette, lowHeight: height - view.safeAreaInsets.bottom)
        sheet.onWillClose = { [weak input] in input?.becomeFirstResponder() }
        sheet.onDidClose = { [weak self] in self?.emojiPaletteDidClose() }
        emojiSheet = sheet
        logger.info("profile edit emoji palette: presenting (height=\(height))")
        input.resignFirstResponder()
        sheet.present(from: navigationController ?? self)
        scrollToCaret()
    }

    private func emojiPaletteDidClose() {
        emojiSheet = nil
        tableAboveSheet?.isActive = false
        let pending = afterEmojiSheetCloses
        afterEmojiSheetCloses = nil
        pending?()
    }

    /// 絵文字のシートを出していなければtrueを返す。出していれば閉じ、閉じ終わってから`action`を行ってfalseを返す。
    /// 絵文字のシートの低い段では、後ろの保存や取りやめのボタンも押せるが、シートを出したままでは確認を重ねたり画面を閉じたりできないため。
    private func closeEmojiSheet(then action: @escaping () -> Void) -> Bool {
        guard let emojiSheet else { return true }
        afterEmojiSheetCloses = action
        if !emojiSheet.isClosing {
            emojiSheet.close(notifiesWillClose: false)
        }
        return false
    }

    private func observeEmojiPalette() {
        guard !isObservingEmojiPalette else { return }
        isObservingEmojiPalette = true
        withObservationTracking {
            updateEmojiPalette()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.isObservingEmojiPalette = false
                guard self?.emojiSheet != nil else { return }
                self?.observeEmojiPalette()
            }
        }
    }

    private func updateEmojiPalette() {
        textCompletion.updatePalette(emojiPalette, recentKeys: paletteRecentKeys)
    }
}

// MARK: - 表

extension ProfileEditViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        editor.draft == nil ? 0 : Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .images, .displayName, .note: 1
        case .fields: fieldRowCount()
        case .flags: 2
        case nil: 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .images:
            return imagesCell
        case .displayName:
            return displayNameCell
        case .note:
            return noteCell
        case .fields:
            guard let field = editor.draft?.fields[safe: indexPath.row] else {
                let cell = UITableViewCell()
                var content = cell.defaultContentConfiguration()
                content.text = "補足情報を追加"
                content.textProperties.color = .tintColor
                cell.contentConfiguration = content
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: ProfileEditFieldCell.reuseIdentifier, for: indexPath)
            if let cell = cell as? ProfileEditFieldCell {
                cell.configure(field: field, settings: settings, accessory: { [weak self] in self?.makeInputAccessory() ?? UIView() }, keys: textCompletion.keys(
                    isShown: { [weak self] in self?.isCompletionListShown == true },
                    growsUpward: { [weak self] in self?.completionList.growsUpward == true }
                ))
                cell.onChange = { [weak self] id, name, value in self?.updateField(id, name: name, value: value) }
                cell.onTextChange = { [weak self] input in self?.textCompletion.textDidChange(in: input) }
                cell.onSelectionChange = { [weak self] input in self?.textCompletion.selectionDidChange(in: input) }
                cell.onBeginEditing = { [weak self] input in self?.inputDidBeginEditing(input) }
                cell.onEndEditing = { [weak self] input in self?.textCompletion.endEditing(in: input) }
            }
            return cell
        case .flags:
            let cell = UITableViewCell()
            // 説明はスイッチごとに、名前の下に小さく出す。
            var content = UIListContentConfiguration.subtitleCell()
            let toggle = indexPath.row == 0 ? lockedSwitch : botSwitch
            content.text = indexPath.row == 0 ? "フォローを承認制にする" : "botのアカウントとして示す"
            content.secondaryText = indexPath.row == 0 ? "フォローのリクエストを承認した人だけがフォローできます" : "自動で投稿するアカウントだと、ほかの人に伝わります"
            content.secondaryTextProperties.color = .secondaryLabel
            // 説明は、区切りの下の説明と同じ小さい文字にする。`subtitleCell`の既定はそれより一回り大きい。
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textToSecondaryTextVerticalPadding = 2
            cell.contentConfiguration = content
            cell.editingAccessoryView = toggle
            cell.accessoryView = toggle
            cell.selectionStyle = .none
            return cell
        case nil:
            return UITableViewCell()
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .displayName: "表示名"
        case .note: "自己紹介"
        case .fields: "補足情報"
        default: nil
        }
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        switch Section(rawValue: section) {
        case .displayName: displayNameFooter
        case .note: noteFooter
        case .fields: fieldsFooter
        default: nil
        }
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        guard Section(rawValue: indexPath.section) == .fields else { return .none }
        return indexPath.row < (editor.draft?.fields.count ?? 0) ? .delete : .insert
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .fields
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        switch editingStyle {
        case .delete: removeField(at: indexPath.row)
        case .insert: addField()
        default: break
        }
    }

    func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        "削除"
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .fields && indexPath.row < (editor.draft?.fields.count ?? 0)
    }

    /// 補足情報の行の中だけで動かす。追加の行より下や、ほかの区切りへは動かさない。
    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        let section = Section.fields.rawValue
        let last = max((editor.draft?.fields.count ?? 1) - 1, 0)
        if proposedDestinationIndexPath.section < section { return IndexPath(row: 0, section: section) }
        if proposedDestinationIndexPath.section > section { return IndexPath(row: last, section: section) }
        return IndexPath(row: min(proposedDestinationIndexPath.row, last), section: section)
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard var fields = editor.draft?.fields, fields.indices.contains(sourceIndexPath.row) else { return }
        let moved = fields.remove(at: sourceIndexPath.row)
        fields.insert(moved, at: min(destinationIndexPath.row, fields.count))
        editor.draft?.fields = fields
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .fields && indexPath.row == (editor.draft?.fields.count ?? 0)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .fields, indexPath.row == (editor.draft?.fields.count ?? 0) else { return }
        addField()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutCompletionListIfShown()
    }
}

// MARK: - 入力欄

extension ProfileEditViewController: UITextFieldDelegate, UITextViewDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard let field = textField as? ProfileEditTextField else { return }
        inputDidBeginEditing(field)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        textCompletion.endEditing(in: textField)
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        textCompletion.selectionDidChange(in: textField)
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        !editor.isSaving
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        noteView.becomeFirstResponder()
        return false
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        inputDidBeginEditing(noteView)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textCompletion.endEditing(in: textView)
    }

    func textViewDidChange(_ textView: UITextView) {
        editor.draft?.note = textView.text
        noteView.updatePlaceholder()
        noteDidChangeHeight()
        textCompletion.textDidChange(in: textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        textCompletion.selectionDidChange(in: textView)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        !editor.isSaving
    }
}

// MARK: - シート

extension ProfileEditViewController: UIAdaptivePresentationControllerDelegate {
    /// 変えたものがあるのに下へスワイプして閉じようとしたら、捨ててよいか確かめる。
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        confirmDiscard()
    }
}

extension ProfileEditViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let image = pickingImage
        pickingImage = nil
        guard let image, let provider = results.first?.itemProvider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            picker.dismiss(animated: true)
            return
        }
        // GIFは、動きを残すよう切り抜かずにそのまま送る。web版も同じく切り抜きを飛ばす。アイコンはサーバーが中央で正方形に切り抜く。
        let isGIF = provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier)
        let type = isGIF ? UTType.gif : UTType.image
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [weak self] data, error in
            let decoded = data.flatMap(ProfileImageCropViewController.decode)
            Task { @MainActor in
                guard let self else { return }
                picker.dismiss(animated: true) {
                    guard let data, let decoded else {
                        self.logger.error("profile image load failed: \(error.map(SciaLog.describe) ?? "decode", privacy: .public)")
                        self.onError(ProfileImageLoadError(), "画像を読み込めませんでした")
                        return
                    }
                    guard isGIF else {
                        self.presentCrop(decoded, for: image)
                        return
                    }
                    self.logger.info("profile image gif kind=\(image.rawValue, privacy: .public) bytes=\(data.count)")
                    self.replaceImage(image, upload: MediaUpload(data: data, filename: "\(image.rawValue).gif", mimeType: "image/gif"), preview: UIImage(cgImage: decoded))
                }
            }
        }
    }
}

/// 選んだ写真を読めなかった。
struct ProfileImageLoadError: LocalizedError {
    var errorDescription: String? { "選んだ画像を読めませんでした。別の画像を選んでください。" }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
