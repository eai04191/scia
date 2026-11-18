import SciaCore
import SwiftUI
import UIKit

/// アプリのプリセットを選ぶ画面。決まりはdocs/preset.mdの「設定の画面」にある。
/// 行を押すとアプリのプリセットに選び、長押しのメニューから、編集（選ばずに中身を変える）、複製、もとにした作成、削除を行う。
struct PresetsView: View {
    let settings: AppSettings
    /// 選ばずに中身を変える画面を開く。
    let openEditor: (PresetID) -> Void
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
        .navigationTitle(SettingsPage.presets.title)
        .background(WindowAnchorView(anchor: anchor))
    }

    private func row(_ id: PresetID) -> some View {
        Button {
            settings.store.updateLibrary { library throws(PresetError) in try library.select(id, for: .app) }
        } label: {
            HStack {
                Text(library.name(of: id) ?? "")
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if library.appPreset == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(library.appPreset == id ? .isSelected : [])
        .contextMenu { menu(for: id) }
        .swipeActions {
            if case .user = id {
                Button(SettingsTexts.Presets.delete, role: .destructive) { deleting = id }
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
            Text(SettingsTexts.Presets.deleteConfirmMessage(parent: isUsed(id) ? parentName(of: id) : nil))
        }
    }

    /// アプリかどれかのアカウントが使っているか。
    private func isUsed(_ id: PresetID) -> Bool {
        library.appPreset == id || library.accountPresets.values.contains(id)
    }

    private func parentName(of id: PresetID) -> String? {
        guard case .user(let number) = id, let parent = library.userPreset(number)?.parent else { return nil }
        return library.name(of: parent)
    }

    @ViewBuilder
    private func menu(for id: PresetID) -> some View {
        if case .user = id {
            Button(SettingsTexts.Presets.edit, systemImage: "pencil") { openEditor(id) }
        }
        Button(SettingsTexts.Presets.duplicate, systemImage: "plus.square.on.square") {
            PresetNameInput.present(from: anchor, title: SettingsTexts.Presets.duplicateTitle, actionTitle: SettingsTexts.Presets.duplicate, text: suggestedName(from: id)) { name throws(PresetError) in
                try settings.store.tryUpdateLibrary { library throws(PresetError) in
                    let duplicated = try library.duplicate(id)
                    try library.rename(duplicated, to: name)
                }
            }
        }
        Button(SettingsTexts.Presets.createChild, systemImage: "plus") {
            PresetNameInput.present(from: anchor, title: SettingsTexts.Presets.createTitle, actionTitle: SettingsTexts.Presets.create, text: suggestedName(from: id)) { name throws(PresetError) in
                var created: PresetID?
                try settings.store.tryUpdateLibrary { library throws(PresetError) in created = try library.create(parent: id, name: name) }
                if let created { openEditor(created) }
            }
        }
        if case .user = id {
            Button(SettingsTexts.Presets.delete, systemImage: "trash", role: .destructive) { deleting = id }
        }
    }
}

extension PresetsView {
    /// 名前を聞くアラートに最初から入れておく名前。もとの名前に、使っていない最小の番号を付ける（「コンパクト 2」）。
    fileprivate func suggestedName(from id: PresetID) -> String {
        var trial = library
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

/// 選んでいるアカウントに、プリセットを割り当てる画面。割り当てなければ、アプリのプリセットを使う。
struct AccountPresetView: View {
    let settings: AppSettings
    let account: String

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            Section {
                choice(title: SettingsTexts.Presets.followsApp, isSelected: library.accountPresets[account] == nil) {
                    settings.store.updateLibrary { $0.unassign(account: account) }
                }
            }
            Section {
                ForEach(BuiltInPreset.allCases, id: \.self) { presetChoice(.builtIn($0)) }
            }
            if !library.userPresets.isEmpty {
                Section(SettingsTexts.Presets.userHeader) {
                    ForEach(library.userPresets, id: \.id) { presetChoice(.user($0.id)) }
                }
            }
        }
        .navigationTitle(SettingsPage.accountPreset.title)
    }

    private func presetChoice(_ id: PresetID) -> some View {
        choice(title: library.name(of: id) ?? "", isSelected: library.accountPresets[account] == id) {
            settings.store.updateLibrary { library throws(PresetError) in try library.select(id, for: .account(account)) }
        }
    }

    private func choice(title: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack {
                Text(title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
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

/// プリセットを選ばずに、その中身を変える画面。名前と、表示・操作・作成の分類を並べる。分類の中の値は、このプリセットに書く。
struct PresetEditorView: View {
    let settings: AppSettings
    let preset: PresetID
    @State private var name: String
    @State private var isNameTaken = false

    init(settings: AppSettings, preset: PresetID) {
        self.settings = settings
        self.preset = preset
        _name = State(initialValue: settings.store.library.name(of: preset) ?? "")
    }

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            Section {
                GlyphLanguageField(placeholder: SettingsTexts.Presets.name, text: $name, settings: settings, onSubmit: rename)
                    .onChange(of: name) { isNameTaken = false }
            } header: {
                Text(SettingsTexts.Presets.name)
            } footer: {
                if isNameTaken {
                    Text(SettingsTexts.Presets.nameTaken)
                        .foregroundStyle(.red)
                }
            }
            if case .user(let number) = preset, let parent = library.userPreset(number)?.parent {
                Section {
                    LabeledContent(SettingsTexts.Presets.parent, value: library.name(of: parent) ?? "")
                }
            }
            Section {
                ForEach([SettingsPage.display, .interaction, .compose], id: \.self) { page in
                    NavigationLink(value: page) { Text(page.rowTitle) }
                }
            }
        }
        .navigationTitle(library.name(of: preset) ?? SettingsPage.presetEditor.title)
        .onDisappear(perform: rename)
    }

    /// 名前を確定する。空か今の名前と同じなら変えない。使っている名前なら断り、下に理由を出す。
    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != library.name(of: preset) else { return }
        do {
            try settings.store.tryUpdateLibrary { library throws(PresetError) in try library.rename(preset, to: trimmed) }
        } catch {
            isNameTaken = error == .nameTaken
        }
    }
}
