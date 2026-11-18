import SciaCore
import SwiftUI
import UIKit

/// アカウントの画面の「外観」。Sciaが従うのにAPIでは変えられないアカウントの設定を見せ、Mastodonのウェブの「外観」の画面へ送る。
/// 開いたときと、アプリに戻ってきたときに読み直す。決まりはdocs/account-screen.mdの「外観」にある。
struct AccountAppearanceView: View {
    let model: AccountPreferencesModel
    /// Mastodonのウェブの「外観」の画面。
    let webURL: URL
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Text(SettingsTexts.AccountAppearance.notEditable)
                Button(SettingsTexts.AccountAppearance.changeOnWeb) { openURL(webURL) }
            }
            // Mastodonのウェブの「外観」の画面と同じ順に並べる。
            Section {
                LabeledContent(SettingsTexts.AccountAppearance.autoplaysAnimations, value: value { onOff($0.autoplaysAnimations) })
                LabeledContent(SettingsTexts.AccountAppearance.mediaDisplay, value: value { $0.mediaDisplay.title })
                LabeledContent(SettingsTexts.AccountAppearance.expandsSpoilers, value: value { onOff($0.expandsSpoilers) })
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(SettingsTexts.AccountAppearance.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reload(purpose: .action) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.reload(purpose: .action)
        }
    }

    /// 読めた値。読めていなければ、読んでいる途中か、読めなかったことを出す。
    private func value(_ text: (ServerPreferences) -> String) -> String {
        if let preferences = model.preferences { return text(preferences) }
        return model.loadFailed ? SettingsTexts.loadFailed : SettingsTexts.AccountAppearance.loadingValue
    }

    private func onOff(_ isOn: Bool) -> String {
        isOn ? SettingsTexts.Presets.on : SettingsTexts.Presets.off
    }
}

extension AccountAppearanceView {
    /// URLから開くときの、単独のシート。
    static func makeSheet(model: AccountPreferencesModel, webURL: URL) -> UIViewController {
        UIHostingController(rootView: AccountAppearanceSheet(model: model, webURL: webURL))
    }
}

private struct AccountAppearanceSheet: View {
    let model: AccountPreferencesModel
    let webURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountAppearanceView(model: model, webURL: webURL)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(SettingsTexts.done) { dismiss() }
                    }
                }
        }
    }
}
