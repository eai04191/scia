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
            Section {
                buildRow("バージョン", value: BuildInfo.current.version)
                buildRow("ビルド", value: BuildInfo.current.build, onTap: registerDeveloperModeTap)
                buildRow("ブランチ", value: BuildInfo.current.branch)
                buildRow("commit", value: BuildInfo.current.commit)
                buildRow("ビルド日時", value: BuildInfo.current.builtAt.formatted(date: .numeric, time: .shortened))
            }
            Section {
                NavigationLink("接続の状態", value: SettingsPage.connection)
                NavigationLink("ライセンス", value: SettingsPage.licenses)
                NavigationLink("謝辞", value: SettingsPage.acknowledgments)
            }
            Section {
                if let repository = AppInfo.repository {
                    Link("ソースコード", destination: repository)
                }
                if let privacyPolicy = AppInfo.privacyPolicy {
                    Link("プライバシーポリシー", destination: privacyPolicy)
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("情報")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { developerMode.resetTaps() }
        .alert(developerMode.isEnabled ? "デバッグメニューをオンにしました" : "デバッグメニューをオフにしました", isPresented: $showsDeveloperModeChanged) {
            Button("OK") {}
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
            .accessibilityAction(named: "コピー") { UIPasteboard.general.string = value }
            .accessibilityAction(named: "すべてコピー") { UIPasteboard.general.string = BuildInfo.current.text }
    }
}

/// 長押しで、押した位置に「コピー」と「すべてコピー」の編集メニューを出す。iPhoneの設定の「情報」の行と同じ出し方。
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
            UIAction(title: "コピー") { [value] _ in UIPasteboard.general.string = value },
            UIAction(title: "すべてコピー") { [all] _ in UIPasteboard.general.string = all },
        ])
    }
}
