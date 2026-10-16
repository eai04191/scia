import SciaCore
import SwiftUI
import UIKit

/// 使う人が選ぶ設定の画面。
struct SettingsView: View {
    @Bindable var settings: AppSettings
    /// 見本の投稿に使う、ログイン中のアカウントを読む。
    let loadPreviewAccount: () async throws -> Account
    /// ログイン中のアカウントのサーバー。
    let instance: URL
    let diagnostics: ConnectionDiagnostics
    @Environment(\.dismiss) private var dismiss
    @State private var previewAccount: Account?
    @State private var previewError: String?
    @State private var previewDate = Date.now.addingTimeInterval(-180)
    @State private var copiedBuildInfo = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let previewAccount {
                        PostPreview(
                            account: previewAccount,
                            createdAt: previewDate,
                            nameStyle: settings.statusNameStyle,
                            timeStyle: settings.statusTimeStyle,
                            avatarShape: settings.avatarShape,
                            animatesAvatars: settings.animatesAvatars,
                            builder: PostContentBuilder(
                                tuning: AppDependencies.tuning,
                                settings: settings,
                                emojiImages: AppDependencies.emojiImages,
                                mediaImages: AppDependencies.mediaImages,
                                avatarImages: AppDependencies.avatarImages
                            )
                        )
                        // 余白は投稿のセルと同じものを、見本の中で取る。
                        .listRowInsets(EdgeInsets())
                    } else if let previewError {
                        Text("見本の投稿を読み込めませんでした。\(previewError)")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("プレビュー")
                }
                Section {
                    Picker("名前の表記", selection: $settings.statusNameStyle) {
                        Text("名前、@acct").tag(StatusNameStyle.nameAndAcct)
                        Text("名前").tag(StatusNameStyle.nameOnly)
                        Text("@acct").tag(StatusNameStyle.acctOnly)
                        Text("@acct、名前").tag(StatusNameStyle.acctAndName)
                    }
                    Picker("時刻の表記", selection: $settings.statusTimeStyle) {
                        Text("相対時刻").tag(StatusTimeStyle.relative)
                        Text("日時").tag(StatusTimeStyle.absolute)
                    }
                    Picker("アイコンの形", selection: $settings.avatarShape) {
                        Text("円").tag(AvatarShape.circle)
                        Text("角丸の四角").tag(AvatarShape.roundedSquare)
                    }
                    Toggle("アイコンのアニメーションを再生する", isOn: $settings.animatesAvatars)
                } header: {
                    Text("投稿の表示")
                } footer: {
                    Text("相対時刻では、1週間より前の投稿は日付で表示します。")
                }
                Section {
                    Picker("最上部での新着の挿入", selection: $settings.insertionMotion) {
                        Text("自動").tag(InsertionMotion.followsSystem)
                        Text("動かして見せる").tag(InsertionMotion.animated)
                        Text("動かさない").tag(InsertionMotion.instant)
                    }
                } header: {
                    Text("動き")
                } footer: {
                    Text("一覧の最上部にいるときに届いた新着を、下から動かして見せるかを選びます。「自動」では、iPhoneの設定の「アクセシビリティ」>「動作」>「視差効果を減らす」がオンのときは動かしません。")
                }
                Section {
                    Toggle("モバイル通信で高画質のサムネイルを使う", isOn: $settings.usesOriginalThumbnailsOnExpensiveNetwork)
                } header: {
                    Text("画像")
                } footer: {
                    Text("オフにすると、モバイル通信とインターネット共有では、サーバーが縮小した画像を一覧に表示します。低データモードでは、この設定にかかわらず縮小した画像を表示します。")
                }
                Section {
                    Toggle("役に立たない代替テキストを無視する", isOn: $settings.ignoresUselessAltText)
                } header: {
                    Text("代替テキスト")
                } footer: {
                    Text("代替テキストが「undefined」や「Screenshot」だけのメディアを、代替テキストのないメディアとして扱います。空白だけの代替テキストは、この設定にかかわらず無視します。")
                }
                Section {
                    NavigationLink("接続の状態") {
                        ConnectionStatusView(instance: instance, diagnostics: diagnostics)
                    }
                    // いろいろなブランチのビルドを入れ替えて試すときに、いま入っているのがどれか分かるようにする。
                    // 違和感の報告などに貼れるよう、タップでコピーする
                    Button {
                        UIPasteboard.general.string = BuildInfo.current.text
                        copiedBuildInfo = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(BuildInfo.current.branch)
                                Text("\(BuildInfo.current.version) @ \(BuildInfo.current.commit)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: copiedBuildInfo ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    // 押すとコピーする行だが、ほかの行と同じ文字の色にそろえる
                    .tint(.primary)
                    .accessibilityHint(copiedBuildInfo ? "コピーしました" : "タップでコピーします")
                    .task(id: copiedBuildInfo) {
                        guard copiedBuildInfo else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedBuildInfo = false
                    }
                }
            }
            .task {
                do {
                    previewAccount = try await loadPreviewAccount()
                } catch {
                    previewError = ErrorPresentation(error).text
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

extension UIViewController {
    /// - Parameters:
    ///   - loadPreviewAccount: 見本の投稿に使う、ログイン中のアカウントを読む。
    ///   - instance: ログイン中のアカウントのサーバー。
    ///   - diagnostics: 「接続の状態」画面に出す、ログイン中のアカウントの接続の状態。
    func presentSettings(loadPreviewAccount: @escaping () async throws -> Account, instance: URL, diagnostics: ConnectionDiagnostics) {
        let view = SettingsView(settings: AppDependencies.settings, loadPreviewAccount: loadPreviewAccount, instance: instance, diagnostics: diagnostics)
        present(UIHostingController(rootView: view), animated: true)
    }
}
