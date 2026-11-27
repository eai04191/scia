import SciaCore
import SwiftUI
import UIKit

/// 設定のトップの画面の、分類の画面へ入る行のラベル。iPhoneの設定アプリと同じアイコンを名前に添える。
struct SettingsCategoryLabel: View {
    let title: String
    let systemImage: String
    /// 四角に敷くシステムカラー。
    let color: UIColor
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = SymbolTile.baseSide

    init(_ title: String, systemImage: String, color: UIColor) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SymbolTile(systemImage: systemImage, color: color, side: iconSide)
        }
    }
}

/// 並びが決まっている設定の画面（表示、操作、作成、メディア、リンク先の読み込み）。何を、どの順で、どんな名前で並べるかは`SettingsPage.sections`にあり、ここは行の部品を選んで描く。
struct SettingsScreenForm: View {
    let page: SettingsPage
    @Bindable var settings: AppSettings
    /// 設定を閉じ、ホームの上でアプリ内のSafariの高さを選ぶシートを出す。
    var openInAppBrowserHeight: @MainActor () -> Void = {}

    var body: some View {
        Form {
            ForEach(sections, id: \.self) { section in
                if section.rows == [.item(.statusBarTicker)] {
                    StatusBarTickerSettingsSection(
                        isOn: $settings.showsStatusBarTicker,
                        isAvailable: StatusBarCutout.isAvailable,
                        isModified: settings.isModified(.statusBarTicker),
                        parentName: settings.parentPresetName
                    ) { settings.reset(.statusBarTicker) }
                } else {
                    SettingsFormSection(header: section.header, footer: footer(of: section)) {
                        ForEach(section.rows, id: \.self) { row in
                            switch row {
                            case .page(let page):
                                NavigationLink(value: page) {
                                    ModifiedLabel(title: page.rowTitle, isModified: settings.isModified(page))
                                }
                                .contextMenu { ResetButton(parentName: settings.parentPresetName, isModified: settings.isModified(page)) { settings.reset(page) } }
                            case .item(let item):
                                itemRow(item)
                                    .contextMenu { ResetButton(parentName: settings.parentPresetName, isModified: settings.isModified(item)) { settings.reset(item) } }
                            }
                        }
                    }
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// このiOSで出せない行と、今の設定で使わない行を除いたセクション。
    private var sections: [SettingsSection] {
        (page.sections ?? []).compactMap { section in
            var section = section
            section.rows.removeAll { row in
                guard Self.isAvailable(row) else { return true }
                if case .item(let item) = row { return !item.isShown(in: settings) }
                return false
            }
            return section.rows.isEmpty ? nil : section
        }
    }

    private static func isAvailable(_ row: SettingsRow) -> Bool {
        guard row == .page(.autoTranslation) else { return true }
        if #available(iOS 26.4, *) { return true }
        return false
    }

    /// セクションの下の説明。iOSの版や機種で決まる説明は、ここで足す。
    private func footer(of section: SettingsSection) -> String? {
        if section.rows.contains(.item(.accentColor)), settings.accentColor.obscuresSelectedTab {
            return SettingsTexts.Display.accentColorObscuresSelectedTab
        }
        return section.footer
    }

    @ViewBuilder
    private func itemRow(_ item: SettingsItem) -> some View {
        switch item {
        case .accentColor: AccentColorPicker(selection: $settings.accentColor, isModified: settings.isModified(.accentColor))
        case .insertionMotion: choicePicker(item, selection: $settings.insertionMotion, title: \.title)
        case .statusBarTicker: StatusBarTickerToggle(isOn: $settings.showsStatusBarTicker, isAvailable: StatusBarCutout.isAvailable, isModified: settings.isModified(.statusBarTicker))
        case .linkBrowser: choicePicker(item, selection: $settings.linkBrowser, title: \.title)
        case .inAppBrowserHeight:
            // 本物のホームの上で選ぶので、設定の上にモーダルビューを出さずに外へ出る。行の見た目は、ほかの画面へ入る行に揃え、シェブロンを付ける。
            Button(action: openInAppBrowserHeight) {
                HStack(spacing: 8) {
                    LabeledContent {
                        Text(SettingsItem.inAppBrowserHeightValue(in: settings))
                    } label: {
                        ModifiedLabel(title: item.title, isModified: settings.isModified(item))
                    }
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .tint(.primary)
        case .reblogVisibility: choicePicker(item, selection: $settings.reblogVisibility, title: \.title)
        case .composeBarIdle: choicePicker(item, selection: $settings.composeBarIdle, title: \.title)
        case .imageUploadSize: choicePicker(item, selection: $settings.imageUploadSize, title: \.title)
        case .videoUploadSize: choicePicker(item, selection: $settings.videoUploadSize, title: \.title)
        case .mediaDynamicRange: choicePicker(item, selection: $settings.mediaDynamicRange, title: \.title)
        case .viewerMediaDynamicRange: choicePicker(item, selection: $settings.viewerMediaDynamicRange, title: \.title)
        case .originalThumbnailsOnExpensiveNetwork: toggle(item, isOn: $settings.usesOriginalThumbnailsOnExpensiveNetwork)
        case .ignoresUselessAltText: toggle(item, isOn: $settings.ignoresUselessAltText)
        case .profilePinned: toggle(item, isOn: $settings.separatesProfilePinned)
        case .profileFeaturedTags: toggle(item, isOn: $settings.showsProfileFeaturedTags)
        case .profileEndorsements: toggle(item, isOn: $settings.showsProfileEndorsements)
        case .profileNoteLength: choicePicker(item, selection: $settings.profileNoteLength, title: \.title)
        case .dynamicProfileAccent: toggle(item, isOn: $settings.usesDynamicProfileAccent)
        case .expandsXPosts: toggle(item, isOn: $settings.expandsXPosts)
        case .version, .build, .branch, .commit, .builtAt, .sourceCode, .privacyPolicy:
            // 情報の画面（`AboutSettingsView`）が描く。
            EmptyView()
        }
    }

    private func choicePicker<Choice: CaseIterable & Hashable>(_ item: SettingsItem, selection: Binding<Choice>, title: KeyPath<Choice, String>) -> some View where Choice.AllCases: RandomAccessCollection {
        Picker(selection: selection) {
            ForEach(Choice.allCases, id: \.self) { choice in
                Text(choice[keyPath: title]).tag(choice)
            }
        } label: {
            ModifiedLabel(title: item.title, isModified: settings.isModified(item))
        }
    }

    @ViewBuilder
    private func toggle(_ item: SettingsItem, isOn: Binding<Bool>) -> some View {
        if item.isInPreset {
            Toggle(isOn: isOn) {
                ModifiedLabel(title: item.title, isModified: settings.isModified(item))
            }
        } else {
            // スイッチの行は1つの要素として読まれ、情報ボタンに届かないので、同じ説明をヒントで読む。
            Toggle(isOn: isOn) {
                NotInPresetLabel(title: item.title)
            }
            .accessibilityHint(SettingsTexts.Presets.notInPreset)
        }
    }
}

/// 見出しと説明があるときだけ、それを付けるセクション。説明は、文中のMarkdownのリンクを選択できるリンクにする。
struct SettingsFormSection<Content: View>: View {
    let header: String?
    let footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        switch (header, footer) {
        case (let header?, let footer?):
            Section { content } header: { Text(header) } footer: { Text(LocalizedStringKey(footer)) }
        case (let header?, nil):
            Section { content } header: { Text(header) }
        case (nil, let footer?):
            Section { content } footer: { Text(LocalizedStringKey(footer)) }
        case (nil, nil):
            Section { content }
        }
    }
}

/// アプリのアイコンを選ぶ画面。
struct AppIconSettingsView: View {
    @State private var appIconError: ErrorPresentation?

    /// 選択の表示は共有のAppIconSelectionから読む。設定を複数のウィンドウで開いていても、どれも同じ選択を表示する。
    private var appIconBinding: Binding<AppIconChoice> {
        Binding {
            AppDependencies.appIcon.current
        } set: { choice in
            appIconError = nil
            Task(.withoutRequests) {
                do {
                    try await AppDependencies.appIcon.select(choice)
                } catch {
                    appIconError = ErrorPresentation(error)
                }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(SettingsTexts.AppIcon.picker, selection: appIconBinding) {
                    ForEach(AppIconChoice.allCases, id: \.self) { choice in
                        AppIconChoiceRow(choice: choice)
                            .tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                if let appIconError {
                    FailureReason(reason: appIconError, lead: SettingsTexts.AppIcon.failureLead)
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(SettingsPage.appIcon.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 設定のトップの画面の、アプリのアイコンの画面へ入る行のラベル。分類の行の色付きの四角の代わりに、いま選んでいるアイコンを同じ大きさで添える。
struct AppIconSettingsLabel: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

    var body: some View {
        Label {
            Text(SettingsPage.appIcon.rowTitle)
        } icon: {
            if let image = AppDependencies.appIcon.current.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                    // 白地のアイコンが行の背景に溶けないよう、選ぶリストと同じく縁を引く
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    }
            }
        }
    }
}

/// ステータスバーの通知の設定。使えない機種では、切り替えをオフにして灰色にし、理由を添える。
struct StatusBarTickerSettingsSection: View {
    @Binding var isOn: Bool
    /// この機種でステータスバーの通知を出せるか。
    let isAvailable: Bool
    /// 読んでいるプリセットが変えたか。変えていれば、長押しのメニューで親のプリセットの値に戻す。
    var isModified = false
    /// 長押しのメニューで従う、親のプリセットの名前。
    var parentName = ""
    var reset: () -> Void = {}

    var body: some View {
        Section {
            StatusBarTickerToggle(isOn: $isOn, isAvailable: isAvailable, isModified: isModified)
                .contextMenu { ResetButton(parentName: parentName, isModified: isModified, reset: reset) }
        } footer: {
            if !isAvailable {
                Text(SettingsTexts.Display.statusBarTickerUnavailable)
            }
        }
    }
}

struct StatusBarTickerToggle: View {
    @Binding var isOn: Bool
    let isAvailable: Bool
    /// 読んでいるプリセットが変えたか。
    var isModified = false

    var body: some View {
        Toggle(isOn: Binding { isAvailable && isOn } set: { isOn = $0 }) {
            ModifiedLabel(title: SettingsItem.statusBarTicker.title, isModified: isModified)
        }
        .disabled(!isAvailable)
    }
}

/// アイコンを選ぶ行。ホーム画面と同じ見た目の絵と名前を並べる。
private struct AppIconChoiceRow: View {
    let choice: AppIconChoice

    var body: some View {
        HStack(spacing: 16) {
            if let image = choice.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 60, height: 60)
                    // 白地のアイコンは行の背景に溶けて輪郭が見えないため、ホーム画面の外でアイコンを見せるときの慣習にならって縁を引く
                    .overlay {
                        RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
            }
            Text(choice.title)
        }
    }
}

/// 名前と、読んでいるプリセットが変えた項目に添えるインジケーター（docs/preset.md）。
struct ModifiedLabel: View {
    let title: String
    let isModified: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            ModifiedIndicator(isModified: isModified)
        }
    }
}

/// プリセットに含めない設定の名前の横に置く情報ボタン。選択すると、どのプリセットでも共通であることをポップオーバーで出す（docs/preset.md）。
struct NotInPresetInfoButton: View {
    @State private var isShown = false

    var body: some View {
        Button {
            isShown = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(SettingsTexts.Presets.notInPresetInfo)
        .popover(isPresented: $isShown) {
            Text(SettingsTexts.Presets.notInPreset)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// 右端に、プリセットに含めないことを示す情報ボタンを添えたラベル。見出しやスイッチの名前に使う。
struct NotInPresetLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer(minLength: 8)
            NotInPresetInfoButton()
        }
    }
}

/// 組み込みのプリセットの名前に添えるロックのアイコン。名前は使う人のプリセットと重なりうるので、アイコンで見分ける（docs/preset.md）。
struct PresetNameLabel: View {
    let name: String
    let isBuiltIn: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isBuiltIn {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(SettingsTexts.Presets.builtIn)
            }
            Text(name)
                .lineLimit(1)
        }
    }
}

/// 長押しのメニューの「“親のプリセット”に従う」。変えた値を、親のプリセットの値に従わせる。
struct ResetButton: View {
    /// 従う親のプリセットの名前（`AppSettings.parentPresetName`）。
    let parentName: String
    let isModified: Bool
    let reset: () -> Void

    var body: some View {
        Button(SettingsTexts.Appearance.followParent(name: parentName), systemImage: "arrow.uturn.backward", action: reset)
            .disabled(!isModified)
    }
}
