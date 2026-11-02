import SciaCore
import SwiftUI
import UIKit

/// 設定の一覧の、分類の画面へ入る行のラベル。iPhoneの設定アプリと同じく、単色を敷いた角丸の四角に白い記号を描いて名前に添える。
struct SettingsCategoryLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    /// 四角の一辺。文字の大きさに合わせて伸ばす。
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(color, in: RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
        }
    }
}

/// 表示の分類。投稿と通知の見た目、新着の動き、ステータスバーの通知、アプリのアイコン。
struct DisplaySettingsView: View {
    @Bindable var settings: AppSettings
    @State private var appIconError: String?

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
                    appIconError = ErrorPresentation(error).text
                }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink("投稿", value: SettingsPage.appearance)
                NavigationLink("通知", value: SettingsPage.notificationAppearance)
            }
            Section {
                Picker("最上部での新着の挿入", selection: $settings.insertionMotion) {
                    Text("自動").tag(InsertionMotion.followsSystem)
                    Text("動かして見せる").tag(InsertionMotion.animated)
                    Text("動かさない").tag(InsertionMotion.instant)
                }
            } footer: {
                Text("「自動」では、「視差効果を減らす」がオンのときは動かしません。")
            }
            StatusBarTickerSettingsSection(isOn: $settings.showsStatusBarTicker, isAvailable: StatusBarCutout.isAvailable)
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
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("表示")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 操作の分類。対象ごとのタップと長押しとメニューの画面、リンクを開く場所、ブーストの公開範囲。
struct InteractionSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                NavigationLink(ObjectEntity.status.title, value: SettingsPage.statusActions)
                NavigationLink(ObjectEntity.notification.title, value: SettingsPage.notificationActions)
                NavigationLink(ObjectEntity.user.title, value: SettingsPage.userActions)
                NavigationLink(ObjectEntity.link.title, value: SettingsPage.linkActions)
                NavigationLink(ObjectEntity.externalPost.title, value: SettingsPage.externalPostActions)
                NavigationLink(ObjectEntity.hashtag.title, value: SettingsPage.hashtagActions)
                NavigationLink(ObjectEntity.media.title, value: SettingsPage.mediaActions)
                NavigationLink("プロフィールの文章", value: SettingsPage.profileTextMenu)
            }
            Section {
                Picker("開く場所", selection: $settings.linkBrowser) {
                    Text("既定のブラウザ").tag(LinkBrowser.external)
                    Text("アプリ内のSafari").tag(LinkBrowser.inApp)
                }
            } header: {
                Text("リンク")
            }
            Section {
                Picker("公開範囲", selection: $settings.reblogVisibility) {
                    Text("アカウントの既定").tag(ReblogVisibility.accountDefault)
                    ForEach([(ReblogVisibility.public, Status.Visibility.public), (.unlisted, .unlisted), (.private, .private)], id: \.0) { reblogVisibility, visibility in
                        Text(VisibilityOption(visibility).title).tag(reblogVisibility)
                    }
                }
            } header: {
                Text("ブースト")
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("操作")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 投稿欄の分類。投稿欄の出し方、ボタンの並び、送る前にメディアを縮める大きさ。
struct ComposeSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("書いていないとき", selection: $settings.composeBarIdle) {
                    Text("隠す").tag(ComposeBarIdle.hidden)
                    Text("折りたたむ").tag(ComposeBarIdle.collapsed)
                    Text("開いたまま").tag(ComposeBarIdle.open)
                }
                NavigationLink("投稿欄のボタン", value: SettingsPage.composeTools)
            }
            Section {
                Picker("画像", selection: $settings.imageUploadSize) {
                    ForEach(ImageUploadSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                Picker("動画", selection: $settings.videoUploadSize) {
                    ForEach(VideoUploadSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
            } header: {
                Text("送る前に縮める")
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("投稿欄")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// メディアの分類。HDRの明るさ、サムネイルの画質、代替テキストの扱い。
struct MediaSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("アプリ", selection: $settings.mediaDynamicRange) {
                    MediaDynamicRangeOptions()
                }
                Picker("ビューア", selection: $settings.viewerMediaDynamicRange) {
                    MediaDynamicRangeOptions()
                }
            } header: {
                Text("HDRのメディアの明るさ")
            }
            Section {
                Toggle("高画質のサムネイル", isOn: $settings.usesOriginalThumbnailsOnExpensiveNetwork)
            } header: {
                Text("モバイル通信")
            }
            Section {
                Toggle("仮の代替テキストを無視", isOn: $settings.ignoresUselessAltText)
            } header: {
                Text("代替テキスト")
            } footer: {
                Text("投稿したアプリが自動で付けたと思われる、説明にならない代替テキストをないものとして扱います。")
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("メディア")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// ステータスバーの通知の設定。使えない機種では、切り替えをオフにして灰色にし、理由を添える。
struct StatusBarTickerSettingsSection: View {
    @Binding var isOn: Bool
    /// この機種でステータスバーの通知を出せるか。
    let isAvailable: Bool

    var body: some View {
        Section {
            Toggle("通知をステータスバーに流す", isOn: Binding { isAvailable && isOn } set: { isOn = $0 })
                .disabled(!isAvailable)
        } footer: {
            if !isAvailable {
                Text("このiPhoneでは使えません。")
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

/// HDRのメディアの明るさの選択肢。アプリとビューアで同じものを並べる。
private struct MediaDynamicRangeOptions: View {
    var body: some View {
        Text("SDR").tag(MediaDynamicRange.standard)
        Text("控えめなHDR").tag(MediaDynamicRange.constrainedHigh)
        Text("HDR").tag(MediaDynamicRange.high)
    }
}
