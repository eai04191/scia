import SciaCore
import SwiftUI

/// 描き方を既定から変えたカスタム絵文字の一覧。決まりはdocs/animated-custom-emoji.mdの「絵文字ごとの描き方」にある。
struct CustomEmojiDisplaySettingsView: View {
    @Bindable var settings: AppSettings
    /// 詳細の画面で開いている絵文字。描き方を選び直すと行が別のセクションへ移ったり一覧から外れたりするので、行の遷移に持たせず、一覧と別に持つ。
    @State private var opened: CustomEmojiDisplayRule?

    var body: some View {
        Form {
            // 画面のどの値もプリセットに含まれないので、セクションごとの情報ボタンではなく、一覧の上に1行で書く。
            Text(SettingsTexts.Presets.notInPreset)
                .foregroundStyle(.secondary)
            if settings.customEmojiDisplayRules.isEmpty {
                Text(SettingsTexts.CustomEmojis.empty)
                    .foregroundStyle(.secondary)
            } else {
                // 行はショートコードとサーバー名の2行を使うので、選んだ描き方は行に置かず、描き方ごとのセクションの見出しにする。
                ForEach(displaySections, id: \.display) { section in
                    Section {
                        ForEach(section.rules) { rule in
                            Button {
                                opened = rule
                            } label: {
                                CustomEmojiDisplayRow(rule: rule, choice: choice)
                            }
                            .foregroundStyle(.primary)
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { section.rules[$0].id })
                            settings.customEmojiDisplayRules.removeAll { ids.contains($0.id) }
                        }
                    } header: {
                        Text(section.display.title)
                    }
                }
            }
        }
        .navigationDestination(item: $opened) { rule in
            CustomEmojiDisplayDetailView(settings: settings, rule: rule, choice: choice)
        }
        .navigationTitle(SettingsPage.customEmojis.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 描き方ごとのセクション。選択肢の順に並べ、セクションの中は描き方を変えた順。変えた絵文字のない描き方のセクションは出さない。
    private var displaySections: [(display: CustomEmojiDisplay, rules: [CustomEmojiDisplayRule])] {
        let rules = settings.customEmojiDisplayRules
        return CustomEmojiDisplay.allCases.compactMap { display in
            let matching = rules.filter { $0.display == display }
            return matching.isEmpty ? nil : (display, matching)
        }
    }

    /// 一覧の画像は、選んだ描き方によらず、ほかの絵文字と同じく設定に従って描く。端末の設定で止めるかは、画像のビューが従う。
    private var choice: EmojiImageChoice {
        AppDependencies.emojiImages.choice(animates: settings.animatesCustomEmojis)
    }
}

/// 一覧の行。ショートコードとサーバー名はどちらも長くなりうるので、1行ずつ使う。長ければ中ほどで切り、全体は行を選択して開く詳細の画面で見る（HIGの「リストとテーブル」）。
private struct CustomEmojiDisplayRow: View {
    let rule: CustomEmojiDisplayRule
    let choice: EmojiImageChoice

    var body: some View {
        HStack(spacing: 12) {
            EmojiImage(rule.emoji, choice: choice, store: AppDependencies.emojiImages)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ":\(rule.id.shortcode):")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: rule.id.domain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

/// 1つの絵文字の詳細。ショートコードとサーバーを切らずに出し、描き方を選び直す。
private struct CustomEmojiDisplayDetailView: View {
    @Bindable var settings: AppSettings
    let rule: CustomEmojiDisplayRule
    let choice: EmojiImageChoice
    @State private var still = KnownStill()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    EmojiImage(rule.emoji, choice: choice, store: AppDependencies.emojiImages)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: ":\(rule.id.shortcode):")
                        Text(verbatim: rule.id.domain)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(CustomEmojiDisplay.choices(isKnownStill: still.isKnownStill, current: current), id: \.self) { display in
                    Button {
                        settings.setCustomEmojiDisplay(display, of: rule.emoji)
                    } label: {
                        HStack {
                            Text(display.title)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if display == current {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityAddTraits(display == current ? .isSelected : [])
                }
            }
        }
        .navigationTitle(Text(verbatim: ":\(rule.id.shortcode):"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { still.watch(rule.url, in: AppDependencies.emojiImages) }
    }

    /// 「表示する」を選ぶと一覧から外れるので、一覧になければ既定の描き方。
    private var current: CustomEmojiDisplay {
        settings.customEmojiDisplayRules.first { $0.id == rule.id }?.display ?? .plays
    }
}

/// 元の画像を読んで動かさないと分かったか。開いたあとで分かっても、選択肢を出し直す。
@MainActor
@Observable
private final class KnownStill {
    private(set) var isKnownStill = false
    @ObservationIgnored private var isWatching = false

    func watch(_ url: URL, in store: EmojiImageStore<UIImage>) {
        isKnownStill = store.isKnownStill(url)
        guard !isWatching else { return }
        isWatching = true
        store.addStillListener(owner: self) { [weak self] urls in
            if urls.contains(url) { self?.isKnownStill = true }
        }
    }
}
