import SciaCore
import SwiftUI
import UIKit

/// 自分のフィルターを並べ、作る、変える、消す。サーバー上のアカウントのものなので、アプリの設定には置かず、アカウントの画面から開く。
/// 決まりはdocs/filters.mdの「作る、変える、消す」にある。
struct FiltersView: View {
    let model: FiltersModel
    let now: () -> Date
    @Environment(\.dismiss) private var dismiss
    /// 編集の画面で作るか変えている下書き。
    @State private var editing: EditedFilter?
    @State private var deleting: ServerFilter?

    /// 編集の画面を開くたびに作り直すための、下書きの入れ物。
    private struct EditedFilter: Identifiable {
        let id = UUID()
        let draft: FilterDraft
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("フィルター")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // 右上は「フィルターを作成」に使うので、閉じるボタンは左に置く。
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完了") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("フィルターを作成", systemImage: "plus") { editing = EditedFilter(draft: FilterDraft()) }
                            .disabled(model.filters == nil)
                    }
                }
        }
        .sheet(item: $editing) { edited in
            FilterEditorView(model: model, now: now, draft: edited.draft)
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
                        Button("削除") { deleting = filter }
                            .tint(.red)
                    }
                }
            }
            .overlay {
                if filters.isEmpty {
                    ContentUnavailableView("フィルターはありません", systemImage: "line.3.horizontal.decrease")
                }
            }
        } else if let failure = model.loadFailure {
            ContentUnavailableView {
                Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
            } description: {
                FailureReason(reason: failure)
            } actions: {
                Button("再読み込み") { model.reload(purpose: .action) }
            }
        } else {
            ProgressView()
        }
    }

    static func makeSheet(model: FiltersModel, now: @escaping () -> Date) -> UIViewController {
        UIHostingController(rootView: FiltersView(model: model, now: now))
    }
}

/// フィルター1つの行。名前、キーワード、扱いと期限を出す。
private struct FilterRow: View {
    let filter: ServerFilter
    let now: Date

    private var isExpired: Bool { filter.expiresAt.map { $0 <= now } ?? false }

    private var detail: String {
        var parts = [FilterWording.label(of: filter.filterAction)]
        if isExpired {
            parts.append("期限切れ")
        } else if let expiresAt = filter.expiresAt {
            parts.append("\(expiresAt.formatted(date: .abbreviated, time: .shortened))まで")
        }
        return parts.joined(separator: "・")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filter.title)
                    .lineLimit(2)
                if !filter.keywords.isEmpty {
                    Text(filter.keywords.map(\.keyword).joined(separator: "、"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(detail)
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
    @State var draft: FilterDraft
    @Environment(\.dismiss) private var dismiss
    @State private var saveFailure: ErrorPresentation?
    @State private var confirmingDiscard = false
    @State private var deleting: ServerFilter?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    GlyphLanguageField(placeholder: "名前", text: $draft.title)
                }
                keywordsSection
                Section("対象") {
                    ForEach(FilterDraft.contextChoices, id: \.self) { context in
                        Toggle(FilterWording.label(of: context), isOn: Binding {
                            draft.contexts.contains(context)
                        } set: { isOn in
                            if isOn { draft.contexts.insert(context) } else { draft.contexts.remove(context) }
                        })
                    }
                }
                Section {
                    Picker("一致した投稿", selection: $draft.action) {
                        ForEach(actionChoices, id: \.self) { action in
                            Text(FilterWording.label(of: action)).tag(action)
                        }
                    }
                } footer: {
                    Text(FilterWording.hint(of: draft.action))
                }
                expirySection
                if let original = draft.original {
                    if !original.statuses.isEmpty {
                        Section {
                            LabeledContent("個別に追加した投稿", value: "\(original.statuses.count)件")
                        }
                    }
                    Section {
                        Button("フィルターを削除", role: .destructive) { deleting = original }
                    }
                }
            }
            // 送っている間に変えたものは保存されないので、送り終えるまで変えさせない。
            .disabled(model.isSaving)
            .navigationTitle(draft.original == nil ? "新規フィルター" : "フィルターを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        if draft.hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                    // 送り始めた保存は止められないので、送り終えるまで閉じさせない。
                    .disabled(model.isSaving)
                    .confirmationDialog("", isPresented: $confirmingDiscard) {
                        Button("変更を破棄", role: .destructive) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button("保存", action: save)
                            .disabled(!draft.canSave || !draft.hasChanges)
                    }
                }
            }
            // 書いたものを、下にスワイプして閉じたときに失わないようにする。
            .interactiveDismissDisabled(draft.hasChanges || model.isSaving)
            .failureAlert("フィルターを保存できませんでした", reason: $saveFailure)
            .filterDeletion(of: $deleting, model: model) { dismiss() }
        }
    }

    /// キーワードごとに、入力欄の行とスイッチの行を持つセクションを並べる。1行に詰めると、スイッチが行の下に寄るため。
    @ViewBuilder
    private var keywordsSection: some View {
        ForEach($draft.keywords) { $keyword in
            Section {
                GlyphLanguageField(placeholder: "キーワードまたはフレーズ", text: $keyword.keyword, corrects: false)
                    .swipeActions {
                        Button("削除", role: .destructive) { draft.keywords.removeAll { $0.id == keyword.id } }
                    }
                Toggle("単語全体に一致", isOn: $keyword.wholeWord)
            } header: {
                if keyword.id == draft.keywords.first?.id {
                    Text("キーワード")
                }
            }
        }
        Section {
            Button("キーワードを追加") { draft.addKeyword() }
        } header: {
            if draft.keywords.isEmpty {
                Text("キーワード")
            }
        }
    }

    private var expirySection: some View {
        Section {
            Picker("期限", selection: $draft.expiry) {
                if draft.original != nil {
                    Text("変更しない").tag(ServerFilter.ExpiryChange.keep)
                }
                ForEach(UserRelationChange.muteDurations, id: \.title) { choice in
                    Text(choice.title).tag(choice.duration.map(ServerFilter.ExpiryChange.after) ?? .never)
                }
            }
        } footer: {
            if let original = draft.original {
                Text(FilterWording.currentExpiry(of: original, now: now()))
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
                filter.map { "フィルター“\($0.title)”を削除しますか？" } ?? "",
                isPresented: Binding { filter != nil } set: { if !$0 { filter = nil } },
                presenting: filter
            ) { filter in
                Button("削除", role: .destructive) {
                    model.delete(filter.id) { failure in
                        if let failure {
                            self.failure = failure
                        } else {
                            onDelete()
                        }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            }
            .failureAlert("フィルターを削除できませんでした", reason: $failure)
    }
}

/// フィルターの画面の文言。
enum FilterWording {
    /// 対象の名前。Mastodonのwebの日本語訳に揃える。
    static func label(of context: FilterResult.Context) -> String {
        switch context {
        case .home: "ホームとリスト"
        case .notifications: "通知"
        case .public: "公開タイムライン"
        case .thread: "会話"
        case .account: "プロフィール"
        case .other(let rawValue): rawValue
        }
    }

    static func label(of action: FilterResult.Action) -> String {
        switch action {
        case .warn: "警告"
        case .hide: "隠す"
        case .blur: "メディアをぼかす"
        case .other(let rawValue): rawValue
        }
    }

    static func hint(of action: FilterResult.Action) -> String {
        switch action {
        case .warn: "フィルターの名前を出して折りたたみます。"
        case .hide: "タイムラインに表示しません。"
        case .blur: "本文はそのまま表示し、メディアをぼかします。"
        case .other: "このアプリでは、警告と同じに扱います。"
        }
    }

    static func currentExpiry(of filter: ServerFilter, now: Date) -> String {
        guard let expiresAt = filter.expiresAt else { return "今の期限は無期限です。" }
        let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
        return expiresAt <= now ? "\(date)に期限が切れています。" : "今の期限は\(date)です。"
    }
}
