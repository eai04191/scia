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
            .navigationTitle("通知のフィルタリング")
            .navigationBarTitleDisplayMode(.inline)
            .task(.action) { model.reload(purpose: .action) }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isSupported {
            ContentUnavailableView("このサーバーでは使えません", systemImage: "nosign", description: Text("通知のフィルタリングはMastodon 4.3から使えます。"))
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
            .confirmationDialog(
                confirmingDrop?.dropConfirmationTitle ?? "",
                isPresented: Binding(get: { confirmingDrop != nil }, set: { if !$0 { confirmingDrop = nil } }),
                titleVisibility: .visible,
                presenting: confirmingDrop
            ) { item in
                Button("“無視”に設定", role: .destructive) { model.select(.drop, for: item) }
                Button("“保留”に設定") { model.select(.filter, for: item) }
                Button("キャンセル", role: .cancel) {}
            } message: { _ in
                Text("無視した通知はサーバーが作らず、あとから見られません。“保留”にすると保留中の通知で個別に確認できます。")
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

    @ViewBuilder
    private func row(for item: NotificationPolicy.Item, value: NotificationPolicy.Value) -> some View {
        if case .unknown = value {
            // サーバーが知らない値を返した項目は、選べない形で出し、送らない。
            LabeledContent(item.title, value: "不明")
        } else {
            Picker(item.title, selection: Binding(get: { value }, set: { choose($0, for: item) })) {
                ForEach(NotificationPolicy.Value.choices, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
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
                        Button("完了") { dismiss() }
                    }
                }
        }
    }
}
