import SciaCore
import SwiftUI
import UIKit

/// 新しく投稿するときの既定。サーバー上のアカウントの設定なので、アプリの設定には置かず、アカウントの画面から開く。
/// 決まりはdocs/account-screen.mdの「投稿のデフォルト」にある。
struct PostingDefaultsView: View {
    let model: PostingDefaultsModel
    let languages: PostingLanguageSource
    @Environment(\.locale) private var locale
    /// 言語を選ぶシートに渡すもの。出している間だけ持つ。
    @State private var languagePicker: PostingLanguagePicker?
    /// シートで選んだ言語の名前。端末が名前を知らない言語でも、サーバーの名前を出すため。
    @State private var chosenLanguageNames: [String: String] = [:]

    var body: some View {
        content
            .topEdgeEffectHiddenOnMac()
            .navigationTitle("投稿のデフォルト")
            .navigationBarTitleDisplayMode(.inline)
            .task(.action) { model.reload(purpose: .action) }
        .sheet(item: $languagePicker) { picker in
            PostingLanguageView(
                picker: picker,
                onSelect: { row in
                    if let code = row.code { chosenLanguageNames[code] = row.name }
                    model.select(.language(row.code))
                },
                close: { languagePicker = nil },
                purpose: .accountDefault
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let preferences = model.preferences {
            Form {
                Section {
                    Picker("公開範囲", selection: Binding(get: { preferences.defaultVisibility }, set: { model.select(.visibility($0)) })) {
                        ForEach(Self.visibilityChoices(including: preferences.defaultVisibility), id: \.self) { visibility in
                            Text(VisibilityOption(visibility).title).tag(visibility)
                        }
                    }
                    if let quotePolicy = model.shownQuotePolicy {
                        Picker("引用できる人", selection: Binding(get: { quotePolicy }, set: { model.select(.quotePolicy($0)) })) {
                            ForEach(QuotePolicy.allCases, id: \.self) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        .disabled(model.quotePolicyFixedReason != nil)
                    }
                } footer: {
                    if model.shownQuotePolicy != nil, let reason = model.quotePolicyFixedReason {
                        Text(reason)
                    }
                }
                Section {
                    Button {
                        // たくさんの言語の中から探さずに済むよう、端末の言語と、投稿欄で最近選んだ言語を候補として先に並べる。
                        let candidates = PostingLanguage.deviceCodes(preferredLanguages: Locale.preferredLanguages) + (languages.recent?.codes ?? [])
                        languagePicker = PostingLanguagePicker(defaultCode: nil, selectedCode: preferences.defaultLanguage, recentCodes: candidates, load: languages.load)
                    } label: {
                        HStack(spacing: 8) {
                            LabeledContent("言語", value: languageName(preferences.defaultLanguage))
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .tint(.primary)
                }
                Section {
                    Toggle("メディアを閲覧注意にする", isOn: Binding(get: { preferences.defaultSensitive }, set: { model.select(.sensitive($0)) }))
                } footer: {
                    Text("メディアを添付すると、注意書きの欄を開きます。")
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

    /// 選べる公開範囲。サーバーが受け付ける3つに、今の値がそれ以外なら今の値を足す。選んでいる値が選択肢にないと、Pickerが何も選んでいない表示になるため。
    private static func visibilityChoices(including current: Status.Visibility) -> [Status.Visibility] {
        let choices = PostingDefaultChange.visibilityChoices
        return choices.contains(current) ? choices : choices + [current]
    }

    private func languageName(_ code: String?) -> String {
        guard let code else { return "サーバーに任せる" }
        return PostingLanguage.localizedName(of: code, in: locale) ?? chosenLanguageNames[code] ?? PostingLanguage.badgeText(of: code)
    }

    /// `scia://posting-defaults`で開く、単独のシート。アカウントの画面からは、その中で進むので使わない。
    static func makeSheet(model: PostingDefaultsModel, languages: PostingLanguageSource) -> UIViewController {
        UIHostingController(rootView: PostingDefaultsSheet(model: model, languages: languages))
    }
}

private struct PostingDefaultsSheet: View {
    let model: PostingDefaultsModel
    let languages: PostingLanguageSource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PostingDefaultsView(model: model, languages: languages)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                    }
                }
        }
    }
}

extension PostingLanguagePicker: @retroactive Identifiable {}
