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
    @State private var appIconError: String?

    /// 選択の表示は共有のAppIconSelectionから読む。設定を複数のウィンドウで開いていても、どれも同じ選択を表示する。
    private var appIconBinding: Binding<AppIconChoice> {
        Binding {
            AppDependencies.appIcon.current
        } set: { choice in
            appIconError = nil
            Task {
                do {
                    try await AppDependencies.appIcon.select(choice)
                } catch {
                    appIconError = ErrorPresentation(error).text
                }
            }
        }
    }

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
                    Picker("開く場所", selection: $settings.linkBrowser) {
                        Text("既定のブラウザ").tag(LinkBrowser.external)
                        Text("アプリ内のSafari").tag(LinkBrowser.inApp)
                    }
                } header: {
                    Text("リンク")
                } footer: {
                    Text("URLのリンクを開く場所です。アプリ内のSafariでは、画面の下半分にページを開き、上に一覧を見ながら読めます。読んでいる間も新着が届きます。httpとhttps以外のリンクは、この設定にかかわらず対応するアプリで開きます。")
                }
                Section {
                    NavigationLink("投稿のメニュー") {
                        MenuLayoutSettingsView(title: "投稿のメニュー", layout: $settings.statusMenuLayout)
                    }
                    NavigationLink("ユーザーのメニュー") {
                        MenuLayoutSettingsView(title: "ユーザーのメニュー", layout: $settings.userMenuLayout)
                    }
                } header: {
                    Text("長押しのメニュー")
                } footer: {
                    Text("投稿や通知を長押ししたときのメニューに出す項目と、その並びを選びます。ユーザーのメニューは、投稿のメニューの中に、投稿したユーザーなどのサブメニューとして出ます。")
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
                    Picker("アイコン", selection: appIconBinding) {
                        ForEach(AppIconChoice.allCases, id: \.self) { choice in
                            AppIconChoiceRow(choice: choice)
                                .tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("アプリのアイコン")
                } footer: {
                    if let appIconError {
                        Text("アイコンを変えられませんでした。\(appIconError)")
                    }
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
