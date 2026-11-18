import SciaCore
import SwiftUI
import UIKit

/// 自分のフィルターを並べ、作る、変える、消す。サーバー上のアカウントのものなので、アプリの設定には置かず、アカウントの画面から開く。
/// 決まりはdocs/filters.mdの「作る、変える、消す」にある。
struct FiltersView: View {
    let model: FiltersModel
    let now: () -> Date
    let settings: AppSettings
    /// 編集の画面で作るか変えている下書き。
    @State private var editing: EditedFilter?
    @State private var deleting: ServerFilter?

    /// 編集の画面を開くたびに作り直すための、下書きの入れ物。
    private struct EditedFilter: Identifiable {
        let id = UUID()
        let draft: FilterDraft
    }

    var body: some View {
        content
            .navigationTitle(SettingsTexts.Filters.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(SettingsTexts.Filters.create, systemImage: "plus") { editing = EditedFilter(draft: FilterDraft()) }
                        .disabled(model.filters == nil)
                }
            }
        .sheet(item: $editing) { edited in
            FilterEditorView(model: model, now: now, settings: settings, draft: edited.draft)
        }
        .filterDeletion(of: $deleting, model: model)
        .task(.action) { model.reload(purpose: .action) }
    }

    @ViewBuilder
    private var content: some View {
        if let filters = model.filters {
            List {
                ForEach(filters) { filter in
                    Button {
                        editing = EditedFilter(draft: FilterDraft(editing: filter))
                    } label: {
                        FilterRow(filter: filter, now: now())
                    }
                    .tint(.primary)
                    .swipeActions {
                        // 確かめてから消すので、スワイプしきっても行は残し、消せたらリストから外れる。
                        Button(SettingsTexts.delete) { deleting = filter }
                            .tint(.red)
                    }
                }
            }
            .overlay {
                if filters.isEmpty {
                    ContentUnavailableView(SettingsTexts.Filters.empty, systemImage: "line.3.horizontal.decrease")
                }
            }
        } else if let failure = model.loadFailure {
            ContentUnavailableView {
                Label(SettingsTexts.loadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                FailureReason(reason: failure)
            } actions: {
                Button(SettingsTexts.reload) { model.reload(purpose: .action) }
            }
        } else {
            ProgressView()
        }
    }

    /// `scia://filters`で開く、単独のシート。アカウントの画面からは、その中で進むので使わない。
    static func makeSheet(model: FiltersModel, now: @escaping () -> Date, settings: AppSettings) -> UIViewController {
        UIHostingController(rootView: FiltersSheet(model: model, now: now, settings: settings))
    }
}

private struct FiltersSheet: View {
    let model: FiltersModel
    let now: () -> Date
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FiltersView(model: model, now: now, settings: settings)
                .toolbar {
                    // 右上は「フィルターを作成」に使うので、閉じるボタンは左に置く。
                    ToolbarItem(placement: .cancellationAction) {
                        Button(SettingsTexts.done) { dismiss() }
                    }
                }
        }
    }
}

/// フィルター1つの行。名前、キーワード、扱いと期限を出す。
private struct FilterRow: View {
    let filter: ServerFilter
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filter.title)
                    .lineLimit(2)
                if !filter.keywords.isEmpty {
                    ItemListText(list: TextLists.items(filter.keywords.map(\.keyword)), textStyle: .footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(filter.rowDetail(now: now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// フィルターを作るか変える画面。名前、キーワード、対象、扱い、期限を並べ、「保存」でまとめて送る。
private struct FilterEditorView: View {
    let model: FiltersModel
    let now: () -> Date
    let settings: AppSettings
    @State var draft: FilterDraft
    @Environment(\.dismiss) private var dismiss
    @State private var saveFailure: ErrorPresentation?
    @State private var confirmingDiscard = false
    @State private var deleting: ServerFilter?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    GlyphLanguageField(placeholder: SettingsTexts.Filters.namePlaceholder, text: $draft.title, settings: settings)
                }
                keywordsSection
                Section(SettingsTexts.Filters.contexts) {
                    ForEach(FilterDraft.contextChoices, id: \.self) { context in
                        Toggle(context.title, isOn: Binding {
                            draft.contexts.contains(context)
                        } set: { isOn in
                            if isOn { draft.contexts.insert(context) } else { draft.contexts.remove(context) }
                        })
                    }
                }
                Section {
                    Picker(SettingsTexts.Filters.action, selection: $draft.action) {
                        ForEach(actionChoices, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                } footer: {
                    Text(draft.action.hint)
                }
                expirySection
                if let original = draft.original {
                    if !original.statuses.isEmpty {
                        Section {
                            LabeledContent(SettingsTexts.Filters.statuses, value: SettingsTexts.count(original.statuses.count))
                        }
                    }
                    Section {
                        Button(SettingsTexts.Filters.deleteFilter, role: .destructive) { deleting = original }
                    }
                }
            }
            // 送っている間に変えたものは保存されないので、送り終えるまで変えさせない。
            .disabled(model.isSaving)
            .navigationTitle(SettingsTexts.Filters.editorTitle(isNew: draft.original == nil))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SettingsTexts.cancel) {
                        if draft.hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                    // 送り始めた保存は止められないので、送り終えるまで閉じさせない。
                    .disabled(model.isSaving)
                    .confirmationDialog("", isPresented: $confirmingDiscard) {
                        Button(SettingsTexts.Filters.discardChanges, role: .destructive) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button(SettingsTexts.Filters.save, action: save)
                            .disabled(!draft.canSave || !draft.hasChanges)
                    }
                }
            }
            // 書いたものを、下にスワイプして閉じたときに失わないようにする。
            .interactiveDismissDisabled(draft.hasChanges || model.isSaving)
            .failureAlert(SettingsTexts.Filters.saveFailed, reason: $saveFailure)
            .filterDeletion(of: $deleting, model: model) { dismiss() }
        }
    }

    /// キーワードごとに、入力欄の行とスイッチの行を持つセクションを並べる。1行に詰めると、スイッチが行の下に寄るため。
    @ViewBuilder
    private var keywordsSection: some View {
        ForEach($draft.keywords) { $keyword in
            Section {
                GlyphLanguageField(placeholder: SettingsTexts.Filters.keywordPlaceholder, text: $keyword.keyword, settings: settings, corrects: false)
                    .swipeActions {
                        Button(SettingsTexts.delete, role: .destructive) { draft.keywords.removeAll { $0.id == keyword.id } }
                    }
                Toggle(SettingsTexts.Filters.wholeWord, isOn: $keyword.wholeWord)
            } header: {
                if keyword.id == draft.keywords.first?.id {
                    Text(SettingsTexts.Filters.keywords)
                }
            }
        }
        Section {
            Button(SettingsTexts.Filters.addKeyword) { draft.addKeyword() }
        } header: {
            if draft.keywords.isEmpty {
                Text(SettingsTexts.Filters.keywords)
            }
        }
    }

    private var expirySection: some View {
        Section {
            Picker(SettingsTexts.Filters.expiry, selection: $draft.expiry) {
                if draft.original != nil {
                    Text(ServerFilter.keepExpiryTitle).tag(ServerFilter.ExpiryChange.keep)
                }
                ForEach(UserRelationChange.muteDurations, id: \.title) { choice in
                    Text(choice.title).tag(choice.duration.map(ServerFilter.ExpiryChange.after) ?? .never)
                }
            }
        } footer: {
            if let original = draft.original {
                Text(original.currentExpiryText(now: now()))
            }
        }
    }

    /// 選べる扱い。サーバーがこのアプリの知らない扱いを返していたら、選び直すまで残せるよう、それも並べる。
    private var actionChoices: [FilterResult.Action] {
        let known: [FilterResult.Action] = [.warn, .hide, .blur]
        return known.contains(draft.action) ? known : known + [draft.action]
    }

    private func save() {
        model.save(draft) { failure in
            if let failure {
                saveFailure = failure
            } else {
                dismiss()
            }
        }
    }
}

private extension View {
    /// リストの削除と同じくアラートで確かめてから、フィルターを消す。消せなかったら、理由をアラートで出す。
    /// - Parameter onDelete: 消せたら呼ぶ。
    func filterDeletion(of filter: Binding<ServerFilter?>, model: FiltersModel, onDelete: @escaping @MainActor () -> Void = {}) -> some View {
        modifier(FilterDeletionModifier(filter: filter, model: model, onDelete: onDelete))
    }
}

private struct FilterDeletionModifier: ViewModifier {
    @Binding var filter: ServerFilter?
    let model: FiltersModel
    let onDelete: @MainActor () -> Void
    @State private var failure: ErrorPresentation?

    func body(content: Content) -> some View {
        content
            .alert(
                filter.map { SettingsTexts.Filters.deleteConfirmation(title: $0.title) } ?? "",
                isPresented: Binding { filter != nil } set: { if !$0 { filter = nil } },
                presenting: filter
            ) { filter in
                Button(SettingsTexts.delete, role: .destructive) {
                    model.delete(filter.id) { failure in
                        if let failure {
                            self.failure = failure
                        } else {
                            onDelete()
                        }
                    }
                }
                Button(SettingsTexts.cancel, role: .cancel) {}
            }
            .failureAlert(SettingsTexts.Filters.deleteFailed, reason: $failure)
    }
}
