import SciaCore
import SwiftUI

struct UserDisplaySettingsView: View {
    @Bindable var settings: AppSettings
    let open: @MainActor (String) -> Void
    let loader: UserDisplayLoader

    var body: some View {
        Form {
            Text(SettingsTexts.Presets.notInPreset)
                .foregroundStyle(.secondary)
            if keys.isEmpty {
                Text(UserDisplayTexts.empty)
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(keys, id: \.self) { key in
                        Button {
                            open(key)
                        } label: {
                            UserDisplaySettingsRow(handle: key, display: loader.display(for: key), settings: settings)
                        }
                        .foregroundStyle(.primary)
                        .onAppear { loader.load(key) }
                        .onChange(of: loader.display(for: key).customAvatar) { loader.load(key) }
                        .onDisappear { loader.cancel(key) }
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { keys[$0] }
                        for key in removed { settings.userDisplays.remove(forKey: key) }
                    }
                }
            }
        }
        .navigationTitle(SettingsPage.userDisplays.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var keys: [String] { settings.userDisplays.rules.keys.sorted() }
}

private struct UserDisplaySettingsRow: View {
    let handle: String
    let display: UserDisplay
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            AvatarImage(url: display.avatarStatic, shape: settings.appearance.avatarShape)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                name
                Text(verbatim: "@" + handle)
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

    @ViewBuilder
    private var name: some View {
        if display.emojis.isEmpty {
            Text(verbatim: display.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            RichTextLabel(numberOfLines: 1, animatesEmojis: settings.animatesCustomEmojis) {
                RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, settings: settings, emojiImages: AppDependencies.emojiImages, language: settings.glyphLanguageIdentifier())
                    .render(.plain(display.name, emojis: display.emojis))
            }
        }
    }

}
