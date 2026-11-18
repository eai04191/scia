import SciaCore
import SwiftUI
import UIKit

/// 「プリセット」の画面。アプリとアカウントごとに使うプリセットを選ぶだけにし、作る・直すは「プリセットを管理」に分ける。決まりはdocs/preset.mdの「選ぶ」にある。
struct PresetsView: View {
    let settings: AppSettings
    /// ログインしているアカウントのハンドル。アカウントの切り替えのメニューと同じ順。1つだけなら、アカウントの節を出さない。
    let accounts: [String]

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsPage.appPreset) {
                    LabeledContent(SettingsTexts.Presets.app, value: library.name(of: library.appPreset) ?? "")
                }
            }
            if accounts.count > 1 {
                Section(SettingsTexts.Presets.accountsHeader) {
                    ForEach(accounts, id: \.self) { account in
                        NavigationLink {
                            AccountPresetView(settings: settings, account: account)
                        } label: {
                            accountLabel(account)
                        }
                    }
                }
            }
            Section {
                NavigationLink(SettingsTexts.Presets.manage, value: SettingsPage.presetManagement)
            }
        }
        .navigationTitle(SettingsPage.presets.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 割り当てていないアカウントには値を出さない。長いハンドルで値が2段目に落ちて行の高さが揃わなくならないよう、ハンドルを中央で省略して1行に収める。
    private func accountLabel(_ account: String) -> some View {
        HStack(spacing: 8) {
            Text(account)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let assigned = library.accountPresets[account].flatMap(library.name(of:)) {
                Text(assigned)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「プリセットを管理」の画面。プリセットを並べ、押すとそのプリセットの画面を開く。押しても使うものは替わらない。決まりはdocs/preset.mdの「作る・直す」にある。
struct PresetManagementView: View {
    let settings: AppSettings
    /// プリセットの画面を開く。
    let openPreset: (PresetID) -> Void
    /// 2つのプリセットを比べる画面を開く。
    let openComparison: () -> Void
    @State private var deleting: PresetID?
    /// この画面を出している窓。名前を聞くアラートを、操作した窓に出すために読む。
    @State private var anchor = WindowAnchor()

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            Section {
                ForEach(BuiltInPreset.allCases, id: \.self) { row(.builtIn($0)) }
            }
            if !library.userPresets.isEmpty {
                Section(SettingsTexts.Presets.userHeader) {
                    ForEach(library.userPresets, id: \.id) { row(.user($0.id)) }
                }
            }
        }
        .navigationTitle(SettingsPage.presetManagement.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(SettingsTexts.Presets.compare, systemImage: "square.split.2x1", action: openComparison)
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel(SettingsTexts.Presets.moreMenu)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    create(parent: .builtIn(.standard))
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel(SettingsTexts.Presets.add)
                }
            }
        }
        .background(WindowAnchorView(anchor: anchor))
    }

    private func row(_ id: PresetID) -> some View {
        Button {
            openPreset(id)
        } label: {
            HStack(spacing: 8) {
                PresetNameLabel(name: library.name(of: id) ?? "", isBuiltIn: id.isBuiltIn)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .tint(.primary)
        .contextMenu {
            Button(SettingsTexts.Presets.duplicate, systemImage: "plus.square.on.square") { duplicate(id) }
            Button(SettingsTexts.Presets.createChild, systemImage: "plus") { create(parent: id) }
            if case .user = id {
                Button(SettingsTexts.Presets.delete, systemImage: "trash", role: .destructive) { deleting = id }
            }
        }
        .swipeActions {
            if case .user = id {
                // `.destructive`にすると、SwiftUIが出した確認をすぐに出し直し、そのときに前の確認と一緒に設定の画面まで閉じる（iOS 27で確認）。
                // 出し直す理由はSwiftUIの中で分からないので、役割を付けずに同じ赤だけを付ける。
                Button(SettingsTexts.Presets.delete) { deleting = id }
                    .tint(.red)
            }
        }
        .confirmationDialog(
            SettingsTexts.Presets.deleteConfirmTitle(name: library.name(of: id) ?? ""),
            isPresented: Binding { deleting == id } set: { if !$0 { deleting = nil } },
            titleVisibility: .visible
        ) {
            Button(SettingsTexts.delete, role: .destructive) {
                settings.store.updateLibrary { library throws(PresetError) in try library.delete(id) }
            }
        } message: {
            Text(SettingsTexts.Presets.deleteConfirmMessage(parent: library.isUsed(id) ? library.parentName(of: id) : nil))
        }
    }

    /// `parent`を親にしたプリセットを、名前を聞いてから作り、その画面を開く。
    private func create(parent: PresetID) {
        PresetNameInput.present(from: anchor, title: SettingsTexts.Presets.createTitle, actionTitle: SettingsTexts.Presets.create, text: library.suggestedName(from: parent)) { name throws(PresetError) in
            var created: PresetID?
            try settings.store.tryUpdateLibrary { library throws(PresetError) in created = try library.create(parent: parent, name: name) }
            if let created { openPreset(created) }
        }
    }

    /// 名前を聞いて複製する。複製しても一覧にとどまる。
    private func duplicate(_ id: PresetID) {
        PresetNameInput.present(from: anchor, title: SettingsTexts.Presets.duplicateTitle, actionTitle: SettingsTexts.Presets.duplicate, text: library.suggestedName(from: id)) { name throws(PresetError) in
            try settings.store.tryUpdateLibrary { library throws(PresetError) in
                let duplicated = try library.duplicate(id)
                try library.rename(duplicated, to: name)
            }
        }
    }
}

/// 1つのプリセットの画面。使う人のプリセットは、名前、もとのプリセット、値を変える分類、複製、削除を並べる。
/// 組み込みのプリセットは値を変えず、標準と違う値と「複製して変更」を並べる。決まりはdocs/preset.mdの「作る・直す」にある。
struct PresetEditorView: View {
    /// 値をこのプリセットに書く設定。
    let settings: AppSettings
    let preset: PresetID
    /// 複製したプリセットの画面に替える。
    let openPreset: (PresetID) -> Void
    /// 入力欄で書き換えた名前。書き換えるまではnilで、欄にはプリセットの今の名前を出す。ほかの窓で名前を変えたとき、書き換えていない欄が前の名前で上書きしないため。
    @State private var editedName: String?
    @State private var isNameTaken = false
    @State private var isDeleting = false
    @State private var anchor = WindowAnchor()

    init(settings: AppSettings, preset: PresetID, openPreset: @escaping (PresetID) -> Void) {
        self.settings = settings
        self.preset = preset
        self.openPreset = openPreset
    }

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            switch preset {
            case .user(let number): userSections(number)
            case .builtIn(let builtIn): builtInSections(builtIn)
            }
        }
        .navigationTitle(library.name(of: preset) ?? SettingsPage.presetEditor.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: rename)
        .background(WindowAnchorView(anchor: anchor))
    }

    @ViewBuilder
    private func userSections(_ number: Int) -> some View {
        Section {
            GlyphLanguageField(placeholder: SettingsTexts.Presets.name, text: nameBinding, settings: settings, onSubmit: rename)
        } header: {
            Text(SettingsTexts.Presets.name)
        } footer: {
            if isNameTaken {
                Text(SettingsTexts.Presets.nameTaken)
                    .foregroundStyle(.red)
            }
        }
        if let parent = library.userPreset(number)?.parent {
            Section {
                LabeledContent(SettingsTexts.Presets.parent, value: library.name(of: parent) ?? "")
            }
        }
        Section {
            ForEach([SettingsPage.display, .interaction, .compose], id: \.self) { page in
                NavigationLink(value: page) {
                    if let icon = page.categoryIcon {
                        SettingsCategoryLabel(page.rowTitle, systemImage: icon.systemImage, color: icon.color)
                    }
                }
            }
        }
        Section {
            Button(SettingsTexts.Presets.duplicate) { duplicate() }
        }
        Section {
            Button(SettingsTexts.Presets.deletePreset, role: .destructive) { isDeleting = true }
                .frame(maxWidth: .infinity, alignment: .leading)
                .confirmationDialog(
                    SettingsTexts.Presets.deleteConfirmTitle(name: library.name(of: preset) ?? ""),
                    isPresented: $isDeleting,
                    titleVisibility: .visible
                ) {
                    Button(SettingsTexts.delete, role: .destructive) {
                        settings.store.updateLibrary { library throws(PresetError) in try library.delete(preset) }
                    }
                } message: {
                    Text(SettingsTexts.Presets.deleteConfirmMessage(parent: library.isUsed(preset) ? library.parentName(of: preset) : nil))
                }
        }
    }

    @ViewBuilder
    private func builtInSections(_ builtIn: BuiltInPreset) -> some View {
        let comparison = PresetComparison(
            base: settings.editing(.builtIn(.standard)),
            compared: settings,
            languageName: PresetComparisonView.languageName,
            deviceLanguageName: PresetComparisonView.languageName(Locale.current.language.minimalIdentifier)
        )
        Section {
            Button(SettingsTexts.Presets.duplicateToEdit) { duplicate() }
        } footer: {
            if builtIn == .standard {
                Text(SettingsTexts.Presets.standardFooter)
            }
        }
        if !comparison.sections.isEmpty {
            ForEach(comparison.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        PresetComparisonRow(row: row, baseName: BuiltInPreset.standard.title, targetName: builtIn.title)
                    }
                }
            }
        }
    }

    /// 名前を聞いて複製し、複製したプリセットの画面に替える。
    private func duplicate() {
        PresetNameInput.present(from: anchor, title: SettingsTexts.Presets.duplicateTitle, actionTitle: SettingsTexts.Presets.duplicate, text: library.suggestedName(from: preset)) { name throws(PresetError) in
            var duplicated: PresetID?
            try settings.store.tryUpdateLibrary { library throws(PresetError) in
                let id = try library.duplicate(preset)
                try library.rename(id, to: name)
                duplicated = id
            }
            if let duplicated { openPreset(duplicated) }
        }
    }

    /// 名前を確定する。空か今の名前と同じなら変えない。使っている名前なら断り、下に理由を出す。
    private var nameBinding: Binding<String> {
        Binding {
            editedName ?? library.name(of: preset) ?? ""
        } set: { newValue in
            editedName = newValue
            isNameTaken = false
        }
    }

    private func rename() {
        guard case .user = preset, let editedName else { return }
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != library.name(of: preset) else { return }
        do {
            try settings.store.tryUpdateLibrary { library throws(PresetError) in try library.rename(preset, to: trimmed) }
            self.editedName = nil
        } catch {
            isNameTaken = error == .nameTaken
        }
    }
}

extension View {
    /// 値を変える画面のサブタイトルに、`settings`が直しているプリセットを出す（docs/preset.md）。
    func presetEditingSubtitle(_ settings: AppSettings) -> some View {
        navigationSubtitle(SettingsTexts.Presets.editing(name: settings.store.observedLibrary.name(of: settings.presetID) ?? ""))
    }
}

extension PresetID {
    var isBuiltIn: Bool {
        if case .builtIn = self { true } else { false }
    }
}

extension PresetLibrary {
    /// アプリかどれかのアカウントが使っているか。
    fileprivate func isUsed(_ id: PresetID) -> Bool {
        appPreset == id || accountPresets.values.contains(id)
    }

    fileprivate func parentName(of id: PresetID) -> String? {
        guard case .user(let number) = id, let parent = userPreset(number)?.parent else { return nil }
        return name(of: parent)
    }

    /// 名前を聞くアラートに最初から入れておく名前。もとの名前に、使っていない最小の番号を付ける（「コンパクト 2」）。
    fileprivate func suggestedName(from id: PresetID) -> String {
        var trial = self
        guard let duplicated = try? trial.duplicate(id) else { return "" }
        return trial.name(of: duplicated) ?? ""
    }
}

/// プリセットを作るときに名前を聞くアラート。使っている名前なら、理由を添えて聞き直す。
/// 入力欄は、ペーストした文字をコピーしたとおりに入れるよう、スマート挿入を切る（`GlyphLanguageTextView`と同じ）。
@MainActor
enum PresetNameInput {
    /// - Parameter anchor: 操作した窓。聞き直すときも、同じ窓に出す。
    static func present(from anchor: WindowAnchor, title: String, actionTitle: String, text: String, message: String? = nil, submit: @escaping (String) throws(PresetError) -> Void) {
        guard let presenter = anchor.view?.window?.rootViewController else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let action = UIAlertAction(title: actionTitle, style: .default) { [weak alert] _ in
            let name = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do throws(PresetError) {
                try submit(name)
            } catch .nameTaken {
                present(from: anchor, title: title, actionTitle: actionTitle, text: name, message: SettingsTexts.Presets.nameTaken, submit: submit)
            } catch {
                // もとのプリセットがほかの窓で消されたときなど。名前を変えても作れないので、聞き直さずに知らせて終える。
                let failure = UIAlertController(title: PresetTexts.presetNotFound, message: nil, preferredStyle: .alert)
                failure.addAction(UIAlertAction(title: SettingsTexts.Presets.ok, style: .default))
                presenter.presentOnFrontmost(failure)
            }
        }
        alert.addTextField { [weak action] field in
            field.text = text
            field.placeholder = SettingsTexts.Presets.name
            field.clearButtonMode = .whileEditing
            field.smartInsertDeleteType = .no
            field.addAction(UIAction { [weak action, weak field] _ in
                action?.isEnabled = !(field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, for: .editingChanged)
        }
        action.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.addAction(UIAlertAction(title: SettingsTexts.cancel, style: .cancel))
        alert.addAction(action)
        alert.preferredAction = action
        presenter.presentOnFrontmost(alert)
    }
}

/// SwiftUIの画面を出している窓を読むための、UIKitのビューへの弱い参照。
@MainActor
final class WindowAnchor {
    weak var view: UIView?
}

/// 背景に置いて、`anchor`に自分のビューを入れる。
struct WindowAnchorView: UIViewRepresentable {
    let anchor: WindowAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}

/// アプリのプリセットを選ぶ画面。
struct AppPresetView: View {
    let settings: AppSettings

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            PresetChoiceSections(library: library, selected: library.appPreset) { id in
                settings.store.updateLibrary { library throws(PresetError) in try library.select(id, for: .app) }
            }
        }
        .navigationTitle(SettingsPage.appPreset.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// アカウントに割り当てるプリセットを選ぶ画面。割り当てなければ、アプリのプリセットを使う。
struct AccountPresetView: View {
    let settings: AppSettings
    let account: String

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            Section {
                PresetChoiceRow(title: SettingsTexts.Presets.sameAsApp(name: library.name(of: library.appPreset) ?? ""), isSelected: library.accountPresets[account] == nil) {
                    settings.store.updateLibrary { $0.unassign(account: account) }
                }
            }
            PresetChoiceSections(library: library, selected: library.accountPresets[account], builtInHeader: SettingsTexts.Presets.accountChoiceHeader) { id in
                settings.store.updateLibrary { library throws(PresetError) in try library.select(id, for: .account(account)) }
            }
        }
        .navigationTitle(account)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 組み込みのプリセットとマイプリセットを、選ぶ行で並べる。
private struct PresetChoiceSections: View {
    let library: PresetLibrary
    let selected: PresetID?
    var builtInHeader: String?
    let select: (PresetID) -> Void

    var body: some View {
        Section {
            ForEach(BuiltInPreset.allCases, id: \.self) { choice(.builtIn($0)) }
        } header: {
            if let builtInHeader {
                Text(builtInHeader)
            }
        }
        if !library.userPresets.isEmpty {
            Section(SettingsTexts.Presets.userHeader) {
                ForEach(library.userPresets, id: \.id) { choice(.user($0.id)) }
            }
        }
    }

    private func choice(_ id: PresetID) -> some View {
        PresetChoiceRow(title: library.name(of: id) ?? "", isBuiltIn: id.isBuiltIn, isSelected: selected == id) { select(id) }
    }
}

/// 選ぶ画面の1行。選んでいるものにチェックマークを付ける。
private struct PresetChoiceRow: View {
    let title: String
    var isBuiltIn = false
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                PresetNameLabel(name: title, isBuiltIn: isBuiltIn)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
