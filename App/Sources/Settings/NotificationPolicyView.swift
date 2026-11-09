import SciaCore
import SwiftUI
import UIKit

/// 通知のフィルタリングの設定。サーバー上のアカウントの設定なので、アプリの設定には置かず、アカウントのメニューと保留中の通知のリストから開く。
/// 決まりはdocs/notification-filter.mdの「通知のフィルタリングの設定」にある。
struct NotificationPolicyView: View {
    let model: NotificationPolicyModel
    @Environment(\.dismiss) private var dismiss
    /// 「無視」にしてよいか確かめている項目。
    @State private var confirmingDrop: NotificationPolicy.Item?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("通知のフィルタリング")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                    }
                }
        }
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
                            Text(Self.hint(of: item))
                        }
                    }
                }
            }
            .confirmationDialog(
                confirmingDrop.map { "本当に“\(Self.title(of: $0))”を無視するようにしますか？" } ?? "",
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
            LabeledContent(Self.title(of: item), value: "不明")
        } else {
            Picker(Self.title(of: item), selection: Binding(get: { value }, set: { choose($0, for: item) })) {
                ForEach(NotificationPolicy.Value.choices, id: \.self) { choice in
                    Text(Self.label(of: choice)).tag(choice)
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

    /// 項目の名前。Mastodonのwebの日本語訳に揃える。
    static func title(of item: NotificationPolicy.Item) -> String {
        switch item {
        case .notFollowing: "フォローしていないアカウントからの通知"
        case .notFollowers: "フォローされていないアカウントからの通知"
        case .newAccounts: "新しいアカウントからの通知"
        case .privateMentions: "外部からの非公開の返信"
        case .limitedAccounts: "モデレーションされたアカウントからの通知"
        }
    }

    /// 項目の説明。Mastodonのwebの日本語訳に揃える。日数（3日と30日）は、APIで返らず、webも文言に決まった値で書いているため、同じ値にする。
    static func hint(of item: NotificationPolicy.Item) -> String {
        switch item {
        case .notFollowing: "手動で通知を受け入れたアカウントは対象外です"
        case .notFollowers: "フォローされていてもフォローから3日経っていない場合は対象になります"
        case .newAccounts: "作成から30日以内のアカウントが対象です"
        case .privateMentions: "メンションした相手からの返信、およびフォローしているアカウントからの返信は対象外です"
        case .limitedAccounts: "モデレーターにより制限されたアカウントから送られる通知が対象です"
        }
    }

    static func label(of value: NotificationPolicy.Value) -> String {
        switch value {
        case .accept: "受け入れ"
        case .filter: "保留"
        case .drop: "無視"
        case .unknown: "不明"
        }
    }

    static func makeSheet(model: NotificationPolicyModel) -> UIViewController {
        UIHostingController(rootView: NotificationPolicyView(model: model))
    }
}
