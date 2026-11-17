import SciaCore
import SwiftUI
import UIKit

/// 通知のフィルタリングの設定。サーバー上のアカウントの設定なので、アプリの設定には置かず、アカウントのメニューと保留中の通知のリストから開く。
/// 決まりはdocs/notification-filter.mdの「通知のフィルタリングの設定」にある。
struct NotificationPolicyView: View {
    let model: NotificationPolicyModel
    /// 「無視」にしてよいか確かめている項目。
    @State private var confirmingDrop: NotificationPolicy.Item?

    var body: some View {
        content
            .navigationTitle(SettingsTexts.NotificationFiltering.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(.action) { model.reload(purpose: .action) }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isSupported {
            ContentUnavailableView(SettingsTexts.NotificationFiltering.unsupported, systemImage: "nosign", description: Text(SettingsTexts.NotificationFiltering.unsupportedDescription))
        } else if let policy = model.policy {
            Form {
                ForEach(NotificationPolicy.Item.allCases, id: \.self) { item in
                    if let value = policy[item] {
                        Section {
                            row(for: item, value: value)
                        } footer: {
                            Text(item.hint)
                        }
                    }
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

    @ViewBuilder
    private func row(for item: NotificationPolicy.Item, value: NotificationPolicy.Value) -> some View {
        if case .unknown = value {
            // サーバーが知らない値を返した項目は、選べない形で出し、送らない。
            LabeledContent(item.title, value: value.title)
        } else {
            Picker(item.title, selection: Binding(get: { value }, set: { choose($0, for: item) })) {
                ForEach(NotificationPolicy.Value.choices, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .confirmationDialog(
                item.dropConfirmationTitle,
                isPresented: Binding(get: { confirmingDrop == item }, set: { if !$0 { confirmingDrop = nil } }),
                titleVisibility: .visible
            ) {
                Button(SettingsTexts.NotificationFiltering.setDrop, role: .destructive) { model.select(.drop, for: item) }
                Button(SettingsTexts.NotificationFiltering.setFilter) { model.select(.filter, for: item) }
                Button(SettingsTexts.cancel, role: .cancel) {}
            } message: {
                Text(SettingsTexts.NotificationFiltering.dropMessage)
            }
        }
    }

    /// 「無視」は、Mastodonのwebと同じく確かめてから送る。
    private func choose(_ value: NotificationPolicy.Value, for item: NotificationPolicy.Item) {
        if value == .drop {
            confirmingDrop = item
        } else {
            model.select(value, for: item)
        }
    }

    /// 保留中の通知のリストと`scia://notification-policy`から開く、単独のシート。アカウントの画面からは、その中で進むので使わない。
    static func makeSheet(model: NotificationPolicyModel) -> UIViewController {
        UIHostingController(rootView: NotificationPolicySheet(model: model))
    }
}

private struct NotificationPolicySheet: View {
    let model: NotificationPolicyModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotificationPolicyView(model: model)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(SettingsTexts.done) { dismiss() }
                    }
                }
        }
    }
}
