import SciaCore
import SwiftUI
import UIKit

/// プリセットの画面。決まりはdocs/preset.mdの「設定の画面」にある。
/// 先頭に、アプリとアカウントごとの今のプリセットを並べ、押すと選ぶ画面を開く。その下にプリセットを並べ、使う人のプリセットは押すと中身を変える画面を開く。
/// 長押しのメニューから、編集、複製、もとにした作成、削除を行う。
struct PresetsView: View {
    let settings: AppSettings
    /// ログインしているアカウントのハンドル。アカウントの切り替えのメニューと同じ順。1つだけなら、アカウントの行を出さない。
    let accounts: [String]
    /// 選ばずに中身を変える画面を開く。
    let openEditor: (PresetID) -> Void
    /// 2つのプリセットを比べる画面を開く。
    let openComparison: () -> Void
    @State private var deleting: PresetID?
    /// この画面を出している窓。名前を聞くアラートを、操作した窓に出すために読む。
    @State private var anchor = WindowAnchor()

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsPage.appPreset) {
                    LabeledContent(SettingsTexts.Presets.app, value: library.name(of: library.appPreset) ?? "")
                }
                if accounts.count > 1 {
                    ForEach(accounts, id: \.self) { account in
                        NavigationLink {
                            AccountPresetView(settings: settings, account: account)
                        } label: {
                            // 長いハンドルで値が2段目に落ちて行の高さが揃わなくならないよう、ハンドルを中央で省略して1行に収める。
                            HStack(spacing: 8) {
                                Text(account)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(library.accountPresets[account].flatMap(library.name(of:)) ?? SettingsTexts.Presets.followsApp)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(SettingsTexts.Presets.compare, systemImage: "square.split.2x1", action: openComparison)
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel(SettingsTexts.Presets.moreMenu)
                }
            }
        }
        .background(WindowAnchorView(anchor: anchor))
    }

    /// 使う人のプリセットは押すと中身を変える画面を開き、組み込みのプリセットは名前だけを出す。
    @ViewBuilder
    private func row(_ id: PresetID) -> some View {
        Group {
            if case .user = id {
                Button {
                    openEditor(id)
                } label: {
                    HStack(spacing: 8) {
                        Text(library.name(of: id) ?? "")
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .tint(.primary)
            } else {
                Text(library.name(of: id) ?? "")
                    .lineLimit(1)
            }
        }
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

/// アプリのプリセットを選ぶ画面。
struct AppPresetView: View {
    let settings: AppSettings

    private var library: PresetLibrary { settings.store.observedLibrary }

    var body: some View {
        Form {
            Section {
                ForEach(BuiltInPreset.allCases, id: \.self) { choice(.builtIn($0)) }
            }
            if !library.userPresets.isEmpty {
                Section(SettingsTexts.Presets.userHeader) {
                    ForEach(library.userPresets, id: \.id) { choice(.user($0.id)) }
                }
            }
        }
        .navigationTitle(SettingsPage.appPreset.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ id: PresetID) -> some View {
        PresetChoiceRow(title: library.name(of: id) ?? "", isSelected: library.appPreset == id) {
            settings.store.updateLibrary { library throws(PresetError) in try library.select(id, for: .app) }
        }
    }
}

/// 選ぶ画面の1行。選んでいるものにチェックマークを付ける。
private struct PresetChoiceRow: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
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
        .navigationTitle(account)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func presetChoice(_ id: PresetID) -> some View {
        choice(title: library.name(of: id) ?? "", isSelected: library.accountPresets[account] == id) {
            settings.store.updateLibrary { library throws(PresetError) in try library.select(id, for: .account(account)) }
        }
    }

    private func choice(title: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        PresetChoiceRow(title: title, isSelected: isSelected, select: select)
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
