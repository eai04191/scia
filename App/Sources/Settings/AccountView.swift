import SciaCore
import SwiftUI
import UIKit

/// アカウントの画面から開くもの。
enum AccountScreenItem: Hashable {
    case profile
    case announcements
    case bookmarks
    case favourites
    case followedTags
    case scheduled
    case list(id: String, title: String)
    case logOut
}

/// アカウントの画面に出すものと、押したときの処理。セッションが作る。
struct AccountScreenContext {
    /// ログイン中のサーバーのドメイン。サーバーが出すものの節の見出しにする。
    let server: String
    /// 未読のお知らせの数。画面を出すたびに読む。
    let unreadAnnouncementCount: @MainActor () -> Int
    /// サーバーに通知のフィルタリングがないと分かっていればfalse。出している間に分かっても消えるよう、画面を描くたびに読む。
    let showsNotificationPolicy: @MainActor () -> Bool
    /// ダミーのアカウントではfalse。ログアウトすると、裏で選んだままの本物のアカウントが消えるため。
    let showsLogOut: Bool
    /// アカウントの画面（設定から開いていれば設定ごと）を閉じてから開く。
    let open: @MainActor (AccountScreenItem) -> Void
    /// 「フィルター」の画面に渡すもの。
    let filters: (model: FiltersModel, now: () -> Date)
    /// 「通知のフィルタリング」の画面に渡すもの。
    let notificationPolicy: NotificationPolicyModel
    /// 「投稿のデフォルト」の画面に渡すもの。
    let postingDefaults: (model: PostingDefaultsModel, languages: PostingLanguageSource)
    /// 名前を入れるアラートを出して、リストを作る。
    let createList: @MainActor () -> Void
    /// 確かめてから、リストを消す。
    let deleteList: @MainActor (_ id: String, _ title: String) -> Void
}

/// アカウントの画面。サーバーにあるものの入口を並べる。決まりはdocs/account-screen.mdにある。
/// アカウントのメニューからはシートで開き、設定からは設定の画面に重ねるので、ナビゲーションは持たない。
struct AccountView: View {
    let settings: AppSettings
    /// ログイン中のアカウントのハンドル。
    let account: String
    let context: AccountScreenContext

    private var unreadAnnouncementCount: Int { context.unreadAnnouncementCount() }

    var body: some View {
        Form {
            Section {
                row("サーバーのお知らせ", value: unreadAnnouncementCount > 0 ? "未読\(unreadAnnouncementCount)件" : nil, opens: .announcements)
            } header: {
                Text(context.server)
            }
            Section {
                row("プロフィール", opens: .profile)
                row("ブックマーク", opens: .bookmarks)
                row("お気に入り", opens: .favourites)
                row("フォロー中のハッシュタグ", opens: .followedTags)
                row("予約投稿", opens: .scheduled)
                NavigationLink("リスト") {
                    AccountListsView(settings: settings, account: account, context: context)
                }
            } header: {
                Text(account)
            }
            Section {
                // この節の画面は投稿やリンクを出さないので、アカウントの画面を閉じずに、この中で進む。
                NavigationLink("投稿のデフォルト") {
                    PostingDefaultsView(model: context.postingDefaults.model, languages: context.postingDefaults.languages)
                }
                NavigationLink("フィルター") {
                    FiltersView(model: context.filters.model, now: context.filters.now)
                }
                if context.showsNotificationPolicy() {
                    NavigationLink("通知のフィルタリング") {
                        NotificationPolicyView(model: context.notificationPolicy)
                    }
                }
            }
            if context.showsLogOut {
                Section {
                    Button("ログアウト", role: .destructive) { context.open(.logOut) }
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, value: String? = nil, opens item: AccountScreenItem) -> some View {
        AccountScreenRow(title: title, value: value) { context.open(item) }
    }
}

/// アカウントの画面を閉じてほかの画面を開く行。ほかの画面へ入る行に揃え、シェブロンを付ける。
private struct AccountScreenRow: View {
    let title: String
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let value {
                    LabeledContent(title, value: value)
                } else {
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .tint(.primary)
    }
}

/// 自分のリストを並べる。押すとそのタイムラインを開き、右上の＋で作り、左へスワイプして消す。
/// リストは、サーバーから読んでタブの並びに反映してあるもの（docs/tabs.mdの「リスト」）を出す。
private struct AccountListsView: View {
    let settings: AppSettings
    let account: String
    let context: AccountScreenContext

    private var lists: [(id: String, title: String)] {
        settings.tabLayout(for: account).elements.compactMap { element in
            guard case .item(.list(let id, let title), _) = element else { return nil }
            return (id, title)
        }
    }

    var body: some View {
        List {
            ForEach(lists, id: \.id) { list in
                AccountScreenRow(title: list.title) { context.open(.list(id: list.id, title: list.title)) }
                    .swipeActions {
                        // 確かめてから消すので、スワイプしきっても行は残し、消せたら並びから外れる。
                        Button("削除") { context.deleteList(list.id, list.title) }
                            .tint(.red)
                    }
            }
        }
        .overlay {
            if lists.isEmpty {
                ContentUnavailableView("リストはありません", systemImage: "list.bullet")
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("リスト")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("リストを作成", systemImage: "plus", action: context.createList)
            }
        }
    }
}

extension UIViewController {
    /// アカウントの画面を、いちばん手前の画面にシートで重ねて出す。
    func presentAccountScreen(settings: AppSettings, account: String, context: AccountScreenContext) {
        let hosting = UIHostingController(rootView: AccountSheet(settings: settings, account: account, context: context))
        presentOnFrontmost(hosting)
    }
}

private struct AccountSheet: View {
    let settings: AppSettings
    let account: String
    let context: AccountScreenContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountView(settings: settings, account: account, context: context)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                    }
                }
        }
    }
}
