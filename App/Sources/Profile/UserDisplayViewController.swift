import os
import PhotosUI
import SciaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class UserDisplayViewController: UITableViewController, PHPickerViewControllerDelegate {
    var onError: (any Error, String) -> Void = { _, _ in }
    private let account: Account
    private let settings: AppSettings
    private let tasks: TaskScope
    private var draft: UserDisplayRule
    private var imageData: Data?
    private var preview: UIImage?
    private var choosingSymbol = false
    let symbolSelection = UserAvatarSelection()
    private let previewCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private var previewAvatar: AvatarView?

    private enum ImageRow { case preview, photo, symbol, symbols, colors, reset }
    private var imageRows: [ImageRow] {
        var rows: [ImageRow] = [.preview, .photo, .symbol]
        if choosingSymbol { rows += [.symbols, .colors] }
        if hasCustomImage { rows.append(.reset) }
        return rows
    }
    private var hasCustomImage: Bool { choosingSymbol || imageData != nil || draft.avatarFile != nil }
    private let nameField = ProfileEditTextField()
    private lazy var nameCell = ProfileEditInputCell(input: nameField)
    private let animationSwitch = UISwitch()
    private let animationCell = UITableViewCell(style: .default, reuseIdentifier: nil)

    init(account: Account, settings: AppSettings, tasks: TaskScope) {
        self.account = account
        self.settings = settings
        self.tasks = tasks.child()
        draft = settings.userDisplays.display(of: account, in: settings).rule
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = UserDisplayTexts.title
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: UserDisplayTexts.save, style: .prominent, target: self, action: #selector(save))
        nameField.text = draft.name
        nameField.placeholder = account.displayNameOrUsername
        nameField.accessibilityLabel = UserDisplayTexts.name
        nameField.followGlyphLanguage(of: settings)
        nameField.addAction(UIAction { [weak self] _ in self?.markEdited() }, for: .editingChanged)
        animationSwitch.isOn = draft.stopsAnimation
        animationSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            draft.stopsAnimation = animationSwitch.isOn
            markEdited()
        }, for: .valueChanged)
        tableView.keyboardDismissMode = .interactive
        AppDependencies.stateDumps.register("userDisplay", owner: self) { $0.stateDump() }
    }

    func stateDump() -> String {
        "hasName: \(!(nameField.text ?? "").isEmpty) hasImage: \(hasCustomImage) rasterizedImage: \(imageData != nil) choosingSymbol: \(choosingSymbol) stopsAnimation: \(draft.stopsAnimation)"
    }

    private func markEdited() {
        navigationController?.isModalInPresentation = true
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0, 1: 2
        case 2: imageRows.count
        default: 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: UserDisplayTexts.original
        case 1: UserDisplayTexts.name
        case 2: UserDisplayTexts.avatar
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0, indexPath.row == 0 {
            let cell = ProfileEditAccountCell(style: .default, reuseIdentifier: nil)
            cell.configure(account: account, avatarShape: settings.appearance.avatarShape, language: settings.glyphLanguageIdentifier(), settings: settings)
            cell.selectionStyle = .none
            return cell
        }
        if indexPath.section == 1, indexPath.row == 0 { return nameCell }
        if indexPath.section == 2, indexPath.row == 0 {
            updatePreview()
            return previewCell
        }
        if indexPath.section == 2, imageRows[indexPath.row] == .symbols || imageRows[indexPath.row] == .colors {
            return symbolChoicesCell(for: imageRows[indexPath.row])
        }
        let cell = indexPath.section == 3 ? animationCell : UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content.text = UserDisplayTexts.scope
            content.textProperties.numberOfLines = 0
            cell.selectionStyle = .none
        } else if indexPath.section == 3 {
            content.text = UserDisplayTexts.stopsAnimation
            animationSwitch.isEnabled = !hasCustomImage
            cell.accessoryView = animationSwitch
            cell.selectionStyle = .none
        } else {
            if indexPath.section == 1 {
                content.text = UserDisplayTexts.resetName
            } else {
                switch imageRows[indexPath.row] {
                case .photo: content.text = UserDisplayTexts.chooseImage
                case .symbol: content.text = UserDisplayTexts.chooseSymbol
                default: content.text = UserDisplayTexts.resetAvatar
                }
            }
            content.textProperties.color = .tintColor
            cell.accessibilityTraits.insert(.button)
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1, indexPath.row == 1 {
            nameField.text = nil
            markEdited()
        } else if indexPath.section == 2, indexPath.row == 1 {
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 1
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            present(picker, animated: true)
        } else if indexPath.section == 2, imageRows[indexPath.row] == .symbol {
            openSymbolChoices()
        } else if indexPath.section == 2, imageRows[indexPath.row] == .reset {
            let oldRows = imageRows
            choosingSymbol = false
            draft.avatarFile = nil
            imageData = nil
            preview = nil
            markEdited()
            updateImageRows(from: oldRows)
        }
    }

    private func updatePreview() {
        previewAvatar?.removeFromSuperview()
        previewAvatar = nil
        previewCell.selectionStyle = .none
        if choosingSymbol {
            previewCell.contentConfiguration = UIHostingConfiguration {
                UserAvatarPreview(selection: symbolSelection, shape: settings.appearance.avatarShape)
            }.margins(.vertical, 16)
            return
        }
        previewCell.contentConfiguration = nil
        let avatar = AvatarView(store: AppDependencies.avatarImages)
        previewAvatar = avatar
        avatar.translatesAutoresizingMaskIntoConstraints = false
        previewCell.contentView.addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: previewCell.contentView.layoutMarginsGuide.leadingAnchor),
            avatar.topAnchor.constraint(equalTo: previewCell.contentView.layoutMarginsGuide.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: previewCell.contentView.layoutMarginsGuide.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 64),
            avatar.heightAnchor.constraint(equalToConstant: 64),
        ])
        if let preview {
            avatar.apply(.init(url: nil, shape: settings.appearance.avatarShape, animates: false))
            let image = UIImageView(image: preview)
            image.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            image.contentMode = .scaleAspectFill
            avatar.addSubview(image)
        } else {
            let url = draft.avatarFile.map { settings.store.userDisplayImageDirectory.appending(fileName: SafeFileName($0)) } ?? account.avatarStatic
            avatar.apply(.init(url: url, shape: settings.appearance.avatarShape, animates: false))
        }
        avatar.isAccessibilityElement = true
        avatar.accessibilityLabel = UserDisplayTexts.avatar
    }

    private func symbolChoicesCell(for row: ImageRow) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if row == .symbols {
            cell.contentConfiguration = UIHostingConfiguration {
                UserAvatarSymbolChoices(selection: symbolSelection)
            }
        } else {
            cell.contentConfiguration = UIHostingConfiguration {
                UserAvatarColorChoices(selection: symbolSelection)
            }
        }
        return cell
    }

    private func openSymbolChoices() {
        guard !choosingSymbol else { return }
        let oldRows = imageRows
        choosingSymbol = true
        markEdited()
        updateImageRows(from: oldRows, revealsChoices: true)
    }

    private func updateImageRows(from oldRows: [ImageRow], revealsChoices: Bool = false) {
        animationSwitch.isEnabled = !hasCustomImage
        let newRows = imageRows
        let removed = oldRows.enumerated().filter { !newRows.contains($0.element) }.map { IndexPath(row: $0.offset, section: 2) }
        let inserted = newRows.enumerated().filter { !oldRows.contains($0.element) }.map { IndexPath(row: $0.offset, section: 2) }
        let animates = view.window != nil && UIView.areAnimationsEnabled && !UIAccessibility.isReduceMotionEnabled
        let update = { [self] in
            for index in removed { tableView.cellForRow(at: index)?.isHidden = true }
            tableView.performBatchUpdates {
                updatePreview()
                tableView.deleteRows(at: removed, with: .none)
                tableView.insertRows(at: inserted, with: animates ? .fade : .none)
            }
            if revealsChoices, view.window != nil {
                tableView.scrollToRow(at: IndexPath(row: 0, section: 2), at: .top, animated: animates)
            }
        }
        if animates { update() } else { UIView.performWithoutAnimation(update) }
    }

    func imageDataForSaving() throws -> Data? {
        guard choosingSymbol else { return imageData }
        let image = try UserAvatarGenerator.image(symbol: symbolSelection.symbol, color: symbolSelection.color)
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    @objc private func save() {
        view.endEditing(true)
        draft.name = nameField.text
        do {
            try settings.userDisplays.save(draft, for: account, in: settings, imageData: imageDataForSaving())
            SciaLog.logger(category: "userDisplay").info("saved custom display")
            dismiss(animated: true)
        } catch {
            SciaLog.logger(category: "userDisplay").error("save failed: \(SciaLog.describe(error), privacy: .public)")
            onError(error, UserDisplayTexts.saveFailure)
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider else {
            picker.dismiss(animated: true)
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
            Task(.withoutRequests) { @MainActor in
                guard let self else { return }
                self.tasks.run(.action) { [weak self] in
                    let decoded = if let data { await ProfileImageCropViewController.decode(data) } else { CGImage?.none }
                    guard let self, !Task.isCancelled else { return }
                    picker.dismiss(animated: true) {
                        guard let decoded else {
                            self.onError(ProfileImageLoadError(), ProfileEditTexts.imageLoadFailure)
                            return
                        }
                        self.presentCrop(decoded)
                    }
                }
            }
        }
    }

    private func presentCrop(_ image: CGImage) {
        let crop = ProfileImageCropViewController(image: image, kind: .avatar, avatarShape: settings.appearance.avatarShape)
        let navigation = UINavigationController(rootViewController: crop)
        navigation.modalPresentationStyle = .fullScreen
        crop.onCancel = { [weak navigation] in navigation?.dismiss(animated: true) }
        crop.onDone = { [weak self, weak navigation] upload, preview in
            guard let self else { return }
            let oldRows = imageRows
            choosingSymbol = false
            imageData = upload.data
            self.preview = preview
            markEdited()
            updateImageRows(from: oldRows)
            navigation?.dismiss(animated: true)
        }
        present(navigation, animated: true)
    }
}
