import SciaCore
import SwiftUI
import UIKit

/// リストのメンバーの画面の＋で開くシート。フォローしている人を探し、押すとリストに足す。もう入っている人を押すと外す。
/// 決まりはdocs/lists.mdの「メンバー」にある。
struct ListMemberSearchView: View {
    let search: @MainActor (String) async throws -> [Account]
    /// 開いたときにリストに入っている人。
    let initialMemberIDs: Set<String>
    /// 足すか外す。送るのはメンバーの画面の持ち主の子で、失敗はメンバーの画面がチップで知らせる。終わったら、サーバーが受け付けたかを渡す。
    let change: @MainActor (_ account: Account, _ adds: Bool, _ completion: @escaping @MainActor (Bool) -> Void) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var results: [Account] = []
    @State private var searchFailure: ErrorPresentation?
    @State private var memberIDs: Set<String> = []
    /// 送っている途中の人。押し直しで二重に送らない。
    @State private var pendingIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if let searchFailure {
                    Text(searchFailure.text)
                        .foregroundStyle(.secondary)
                } else if trimmedQuery.isEmpty {
                    Text("フォローしている人を、名前かハンドルで探します。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { account in
                        row(account)
                    }
                }
            }
            .overlay {
                if !trimmedQuery.isEmpty, searchFailure == nil, results.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
            // 検索欄の閉じるボタンは、語を空にする変更をアニメーション付きで流す。そのままだと、結果の行と案内の行と結果なしの表示が、検索バーが戻る動きのあいだに入れ替わりながら重なり、案内の行がずれた位置から飛んで戻る。
            .animation(nil, value: trimmedQuery)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "フォローしている人を探す")
            .navigationTitle("メンバーを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", action: dismiss)
                }
            }
        }
        .onAppear { memberIDs = initialMemberIDs }
        // 打つたびに探し直し、前の問い合わせは取り消す。
        .task(.action, id: trimmedQuery) {
            await runSearch(trimmedQuery)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runSearch(_ text: String) async {
        guard !text.isEmpty else {
            results = []
            searchFailure = nil
            return
        }
        do {
            let found = try await search(text)
            guard !Task.isCancelled else { return }
            results = found
            searchFailure = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            searchFailure = ErrorPresentation(error)
        }
    }

    /// 行は、検索の候補の人の行と同じ部品で描く。
    private func row(_ account: Account) -> some View {
        let isMember = memberIDs.contains(account.id)
        let settings = AppDependencies.settings
        let emojiImages = AppDependencies.emojiImages
        return Button {
            toggle(account)
        } label: {
            RowLayout {
                AvatarImage(url: account.avatarStatic ?? account.avatar, shape: settings.appearance.avatarShape)
            } title: {
                RichTextLabel(numberOfLines: 1, emojiImages: emojiImages, animatesEmojis: settings.animatesCustomEmojis, fadesTail: true) {
                    RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline), textColor: .label, emojiImages: emojiImages, language: settings.glyphLanguageIdentifier())
                        .render(.plain(account.displayNameOrUsername, emojis: account.emojis))
                }
            } subtitle: {
                Text("@\(account.acct)").fadingTail(of: account.acct)
            } trailing: {
                if pendingIDs.contains(account.id) {
                    ProgressView()
                } else if isMember {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
        // 標準では文字が色付きになるので、検索の候補と同じく通常の色にする。
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(account.displayNameOrUsername)、@\(account.acct)")
        .accessibilityAddTraits(isMember ? [.isButton, .isSelected] : .isButton)
        .disabled(pendingIDs.contains(account.id))
    }

    private func toggle(_ account: Account) {
        let isMember = memberIDs.contains(account.id)
        pendingIDs.insert(account.id)
        change(account, !isMember) { accepted in
            pendingIDs.remove(account.id)
            guard accepted else { return }
            if isMember {
                memberIDs.remove(account.id)
            } else {
                memberIDs.insert(account.id)
            }
        }
    }
}

extension ListMemberSearchView {
    /// シートで出す画面。
    static func sheet(
        search: @escaping @MainActor (String) async throws -> [Account],
        initialMemberIDs: Set<String>,
        change: @escaping @MainActor (_ account: Account, _ adds: Bool, _ completion: @escaping @MainActor (Bool) -> Void) -> Void
    ) -> UIViewController {
        weak var presented: UIViewController?
        let controller = UIHostingController(rootView: ListMemberSearchView(
            search: search,
            initialMemberIDs: initialMemberIDs,
            change: change
        ) {
            presented?.dismiss(animated: true)
        })
        presented = controller
        return controller
    }
}
