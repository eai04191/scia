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
    /// 時刻の表記の見本に使う日時。
    let previewDate: Date
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
                NavigationLink(value: SettingsPage.appearance) {
                    PostPreview(
                        createdAt: previewDate,
                        nameStyle: settings.appearance.statusNameStyle,
                        timeStyle: settings.appearance.statusTimeStyle,
                        avatarShape: settings.appearance.avatarShape,
                        animatesAvatars: settings.appearance.animatesAvatars,
                        linkCardThumbnailSide: settings.appearance.linkCardThumbnailSide,
                        glyphLanguage: settings.appearance.glyphLanguage,
                        emojiStyle: settings.appearance.emojiStyle,
                        appearanceValues: settings.appearanceValues,
                        builder: PostContentBuilder(
                            tuning: AppDependencies.tuning,
                            settings: settings,
                            emojiImages: AppDependencies.emojiImages,
                            mediaImages: AppDependencies.mediaImages,
                            avatarImages: AppDependencies.avatarImages
                        )
                    )
                    // 見本は押しても動かさず、行全体で「投稿の見た目」を開く。
                    .allowsHitTesting(false)
                }
                // 見本は一覧の行と同じ余白を自分で取るので、行の余白を重ねない。右は、開く印を置くぶんだけ空ける。
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
            } header: {
                Text("投稿の見た目")
            }
            Section {
                NavigationLink("通知の見た目", value: SettingsPage.notificationAppearance)
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

/// 操作の分類。タップと長押し、長押しのメニュー、リンクを開く場所、ブーストの公開範囲。
struct InteractionSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ObjectActionsRow(entity: .status, settings: settings, page: .statusActions)
                ObjectActionsRow(entity: .notification, settings: settings, page: .notificationActions)
                ObjectActionsRow(entity: .user, settings: settings, page: .userActions)
                ObjectActionsRow(entity: .link, settings: settings, page: .linkActions)
                ObjectActionsRow(entity: .externalPost, settings: settings, page: .externalPostActions)
                ObjectActionsRow(entity: .hashtag, settings: settings, page: .hashtagActions)
                ObjectActionsRow(entity: .media, settings: settings, page: .mediaActions)
            } header: {
                Text("タップと長押し")
            }
            Section {
                NavigationLink("投稿のメニュー", value: SettingsPage.statusMenu)
                NavigationLink("ユーザーのメニュー", value: SettingsPage.userMenu)
                NavigationLink("リンクのメニュー", value: SettingsPage.linkMenu)
                NavigationLink("ほかのサービスの投稿のメニュー", value: SettingsPage.externalPostMenu)
                NavigationLink("プロフィールの文章のメニュー", value: SettingsPage.profileTextMenu)
                NavigationLink("ハッシュタグのメニュー", value: SettingsPage.hashtagMenu)
                NavigationLink("メディアのメニュー", value: SettingsPage.mediaMenu)
            } header: {
                Text("長押しのメニュー")
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
                Toggle("書いていないときは隠す", isOn: $settings.hidesEmptyComposeBar)
                Toggle("書いていないときも畳まない", isOn: $settings.keepsComposeBarOpen)
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
                Picker("ビューア以外", selection: $settings.mediaDynamicRange) {
                    MediaDynamicRangeOptions()
                }
                Picker("ビューア", selection: $settings.viewerMediaDynamicRange) {
                    MediaDynamicRangeOptions()
                }
            } header: {
                Text("HDRのメディアの明るさ")
            }
            Section {
                Toggle("モバイル通信で高画質のサムネイルを使う", isOn: $settings.usesOriginalThumbnailsOnExpensiveNetwork)
            }
            Section {
                Toggle("役に立たない代替テキストを無視する", isOn: $settings.ignoresUselessAltText)
            } footer: {
                Text("「undefined」や「Screenshot」だけの代替テキストを、ないものとして扱います。")
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

/// HDRのメディアの明るさの選択肢。ビューア以外とビューアで同じものを並べる。
private struct MediaDynamicRangeOptions: View {
    var body: some View {
        Text("SDR").tag(MediaDynamicRange.standard)
        Text("控えめなHDR").tag(MediaDynamicRange.constrainedHigh)
        Text("HDR").tag(MediaDynamicRange.high)
    }
}
