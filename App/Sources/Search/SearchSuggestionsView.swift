import Observation
import SciaCore
import SwiftUI

/// 検索欄に打っている途中の候補と、検索欄が空のときの最近の検索。決まりはdocs/search.mdの「打っている途中」と「最近の検索」にある。
///
/// 中の入力もスクロール位置の細かい制御も持たない一覧なので、SwiftUIで描き、`UISearchController`の結果の画面として載せる。
/// 行は投稿欄の補完と同じ部品（`RowLayout`）で描く。
@MainActor
@Observable
final class SearchSuggestionsModel {
    var content = SearchSuggestions.Content()
    @ObservationIgnored var settings = AppDependencies.settings
    @ObservationIgnored var emojiImages = AppDependencies.emojiImages
    @ObservationIgnored var onAction: (SearchSuggestions.Action) -> Void = { _ in }
    @ObservationIgnored var onSelectAccount: (Account) -> Void = { _ in }
    @ObservationIgnored var onSelectHashtag: (Hashtag) -> Void = { _ in }
    @ObservationIgnored var onSelectRecent: (String) -> Void = { _ in }
    @ObservationIgnored var onRemoveRecent: (String) -> Void = { _ in }
    @ObservationIgnored var onRemoveAllRecents: () -> Void = {}
}

struct SearchSuggestionsView: View {
    let model: SearchSuggestionsModel

    // 行のボタンは一覧の標準のまま押させる。`.plain`にすると、行を横にスワイプしても指を離したときに押したことになり、最近の検索を消せなかったため。
    // 標準では文字が色付きになるので、行の文字は通常の色にする。
    var body: some View {
        List {
            if !model.content.actions.isEmpty {
                Section {
                    ForEach(model.content.actions, id: \.self) { action in
                        Button { model.onAction(action) } label: { actionLabel(action) }
                            .foregroundStyle(.primary)
                    }
                }
            }
            if !model.content.accounts.isEmpty {
                Section(SearchCategory.accounts.title) {
                    ForEach(model.content.accounts, id: \.id) { account in
                        Button { model.onSelectAccount(account) } label: { accountLabel(account) }
                            .foregroundStyle(.primary)
                    }
                }
            }
            if !model.content.hashtags.isEmpty {
                Section(SearchCategory.hashtags.title) {
                    ForEach(model.content.hashtags, id: \.name) { hashtag in
                        Button { model.onSelectHashtag(hashtag) } label: {
                            RowLayout {
                                Image(systemName: "number").foregroundStyle(.secondary)
                            } title: {
                                Text(hashtag.name).fadingTail(of: hashtag.name)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            if !model.content.recents.isEmpty {
                Section {
                    ForEach(model.content.recents, id: \.self) { query in
                        Button { model.onSelectRecent(query) } label: {
                            RowLayout {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            } title: {
                                Text(query).fadingTail(of: query)
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("消す", role: .destructive) { model.onRemoveRecent(query) }
                        }
                    }
                } header: {
                    HStack {
                        Text("最近の検索")
                        Spacer()
                        Button("すべて消す") { model.onRemoveAllRecents() }
                            .font(.subheadline)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    private func actionLabel(_ action: SearchSuggestions.Action) -> some View {
        let (symbol, title): (String, String) = switch action {
        case .search(let text): ("magnifyingglass", "“\(text)”を検索")
        case .openURL: ("link", "このURLを開く")
        case .openHandle(let acct): ("person.crop.circle", "@\(acct)を開く")
        case .openHashtag(let name): ("number", "#\(name)を開く")
        }
        return RowLayout {
            Image(systemName: symbol).foregroundStyle(.tint)
        } title: {
            Text(title).fadingTail(of: title)
        }
    }

    private func accountLabel(_ account: Account) -> some View {
        RowLayout {
            AvatarImage(url: account.avatarStatic ?? account.avatar, shape: model.settings.appearance.avatarShape)
        } title: {
            RichTextLabel(numberOfLines: 1, emojiImages: model.emojiImages, animatesEmojis: model.settings.appearance.animatesCustomEmojis, fadesTail: true) { [model] in
                RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline), textColor: .label, emojiImages: model.emojiImages, language: model.settings.glyphLanguageIdentifier())
                    .render(.plain(account.displayNameOrUsername, emojis: account.emojis))
            }
        } subtitle: {
            Text("@\(account.acct)").fadingTail(of: account.acct)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(account.displayNameOrUsername)、@\(account.acct)")
    }
}
