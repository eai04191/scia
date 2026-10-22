import SciaCore
import SwiftUI

extension ReportCategory {
    var title: String {
        switch self {
        case .spam: "スパム"
        case .violation: "サーバーのルールへの違反"
        case .legal: "違法な内容"
        case .other: "その他"
        }
    }

    var detail: String {
        switch self {
        case .spam: "宣伝のリンク、同じ内容の繰り返しなど"
        case .violation: "違反したルールを選びます"
        case .legal: "法律に反する内容"
        case .other: "ほかの理由"
        }
    }
}

/// 通報のシート。理由の種類、違反したルール、コメント、ほかのサーバーへの転送を1枚で選ぶ。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
struct ReportView: View {
    @Bindable var draft: ReportDraft
    /// 送れたあと、シートを閉じてから呼ぶ。
    let onSubmitted: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if draft.statusID != nil {
                    Section {
                        Toggle("長押しした投稿を添える", isOn: $draft.includesStatus)
                    }
                }
                Section("理由") {
                    ForEach(ReportCategory.allCases, id: \.self) { category in
                        categoryRow(category)
                    }
                }
                if draft.category == .violation {
                    rulesSection
                }
                Section {
                    // 長く書いても文字数と後ろの項目が押し出されないよう、高さに上限を付けて中でスクロールさせる。
                    TextEditor(text: $draft.comment)
                        .frame(minHeight: 100, maxHeight: 240)
                } header: {
                    Text("補足")
                } footer: {
                    Text("\(draft.commentLength) / \(ReportDraft.commentLimit)")
                        .monospacedDigit()
                        .foregroundStyle(draft.commentLength > ReportDraft.commentLimit ? .red : .secondary)
                }
                if let domain = draft.remoteDomain {
                    // サーバー名は説明文に出す。スイッチの名前に入れると、長いサーバー名で「にも送る」が切れて見えなくなるため。
                    Section {
                        Toggle("相手のサーバーにも送る", isOn: $draft.forward)
                    } footer: {
                        Text("\(domain)の管理者にも、この通報を転送します。")
                    }
                }
                if let error = draft.submitError {
                    Section {
                        Text(ErrorPresentation(error).message)
                            .foregroundStyle(.red)
                    }
                }
            }
            // 送るのは押した時点の内容なので、送っている間に書き換えたものが送られずに消えないよう、触れなくする。
            .disabled(draft.isSubmitting)
            .topEdgeEffectHiddenOnMac()
            // 相手は小見出しに出す。見出しに入れると、長いハンドルで「を通報」が切れて見えなくなるため。
            .navigationTitle("通報")
            .navigationSubtitle("@\(draft.acct)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", role: .cancel) { dismiss() }
                        .disabled(draft.isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft.isSubmitting {
                        ProgressView()
                    } else {
                        Button("送信", action: submit)
                            .disabled(!draft.canSubmit)
                    }
                }
            }
            // 書いたものを、下に払って閉じたときに失わないようにする。
            .interactiveDismissDisabled(draft.isSubmitting || !draft.comment.isEmpty)
            .task {
                await draft.loadRules()
            }
        }
    }

    private func categoryRow(_ category: ReportCategory) -> some View {
        Button {
            draft.category = category
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                    Text(category.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if draft.category == category {
                    // 行の文字を普通の色にするため、ボタンのtintを変えている。印はアプリのアクセントの色で描く。
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        // Formの中のボタンは文字がすべてtintの色になるため、行は普通の文字の色で出す。
        .tint(.primary)
        .accessibilityAddTraits(draft.category == category ? .isSelected : [])
    }

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            switch draft.rules {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .failed(let error):
                VStack(alignment: .leading, spacing: 4) {
                    Text("ルールを読み込めませんでした")
                    Text(ErrorPresentation(error).message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("再試行") {
                    Task { await draft.loadRules() }
                }
            case .loaded(let rules) where rules.isEmpty:
                Text("このサーバーにはルールがありません")
                    .foregroundStyle(.secondary)
            case .loaded(let rules):
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }
        } header: {
            Text("違反したルール")
        }
    }

    private func ruleRow(_ rule: InstanceRule) -> some View {
        let isSelected = draft.selectedRuleIDs.contains(rule.id)
        return Button {
            draft.toggleRule(rule.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.text)
                    if let hint = rule.hint, !hint.isEmpty {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func submit() {
        Task {
            guard await draft.submit() else { return }
            dismiss()
            onSubmitted()
        }
    }
}

extension ReportView {
    /// UIKitの画面から出すシート。
    static func sheet(draft: ReportDraft, onSubmitted: @escaping @MainActor () -> Void) -> UIViewController {
        UIHostingController(rootView: ReportView(draft: draft, onSubmitted: onSubmitted))
    }
}
