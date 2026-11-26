import SciaCore
import SwiftUI
import UIKit

/// 設定の「情報」。iPhoneの設定アプリの「一般」>「情報」と同じく、ビルドを灰色の値の行で並べ、接続の状態、ライセンス、謝辞の画面を開く。
/// プライバシーポリシーは、App Store Connectに載せるものと同じ、リポジトリのPRIVACY.mdを開く。
struct AboutSettingsView: View {
    private let developerMode = AppDependencies.developerMode
    @State private var showsDeveloperModeChanged = false

    var body: some View {
        Form {
            // いろいろなブランチのビルドを入れ替えて試すときに、いま入っているのがどれか分かるようにする。
            // iPhoneの設定の「情報」と同じく、長押しでその行の値をコピーする。違和感の報告などに貼れるよう、全部をまとめてもコピーできる
            ForEach(SettingsPage.about.sections ?? [], id: \.self) { section in
                Section {
                    ForEach(section.rows, id: \.self) { row in
                        switch row {
                        case .page(let page): NavigationLink(page.rowTitle, value: page)
                        case .item(let item): itemRow(item)
                        }
                    }
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(SettingsPage.about.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { developerMode.resetTaps() }
        .alert(SettingsTexts.About.developerModeChanged(isEnabled: developerMode.isEnabled), isPresented: $showsDeveloperModeChanged) {
            Button("OK") {}
        }
    }

    @ViewBuilder
    private func itemRow(_ item: SettingsItem) -> some View {
        switch item {
        case .version: buildRow(item.title, value: BuildInfo.current.version)
        case .build: buildRow(item.title, value: BuildInfo.current.build, onTap: registerDeveloperModeTap)
        case .branch: buildRow(item.title, value: BuildInfo.current.branch)
        case .commit: buildRow(item.title, value: BuildInfo.current.commit)
        case .builtAt: buildRow(item.title, value: BuildInfo.current.builtAt.formatted(date: .numeric, time: .shortened))
        case .sourceCode:
            if let repository = AppInfo.repository {
                Link(item.title, destination: repository)
            }
        case .privacyPolicy:
            if let privacyPolicy = AppInfo.privacyPolicy {
                Link(item.title, destination: privacyPolicy)
            }
        default: EmptyView()
        }
    }

    private func registerDeveloperModeTap() {
        guard developerMode.registerTap() else { return }
        if !developerMode.isEnabled {
            HitAreaOverlay.hideAll()
        }
        showsDeveloperModeChanged = true
    }

    private func buildRow(_ title: String, value: String, onTap: (() -> Void)? = nil) -> some View {
        LabeledContent(title, value: value)
            .overlay {
                CopyMenuArea(value: value, all: BuildInfo.current.text, onTap: onTap)
            }
            .accessibilityAction(named: SettingsTexts.About.copy) { UIPasteboard.general.string = value }
            .accessibilityAction(named: SettingsTexts.About.copyAll) { UIPasteboard.general.string = BuildInfo.current.text }
    }
}

/// 長押しで、長押しした位置に「コピー」と「すべてコピー」の編集メニューを出す。iPhoneの設定の「情報」の行と同じ出し方。
private struct CopyMenuArea: UIViewRepresentable {
    let value: String
    let all: String
    let onTap: (() -> Void)?

    func makeUIView(context: Context) -> CopyMenuView {
        CopyMenuView()
    }

    func updateUIView(_ view: CopyMenuView, context: Context) {
        view.value = value
        view.all = all
        view.onTap = onTap
    }
}

private final class CopyMenuView: UIView, @MainActor UIEditMenuInteractionDelegate {
    var value = ""
    var all = ""
    var onTap: (() -> Void)?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addInteraction(editMenu)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed)))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        onTap?()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: recognizer.location(in: self)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: SettingsTexts.About.copy) { [value] _ in UIPasteboard.general.string = value },
            UIAction(title: SettingsTexts.About.copyAll) { [all] _ in UIPasteboard.general.string = all },
        ])
    }
}
