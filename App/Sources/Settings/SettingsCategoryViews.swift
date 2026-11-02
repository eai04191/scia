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
            } footer: {
                Text("文字の大きさや余白、名前や時刻の表記、お気に入りとブーストの光を、プレビューを見ながら変えます。")
            }
            Section {
                NavigationLink("通知の見た目", value: SettingsPage.notificationAppearance)
            } footer: {
                Text("誰が何をしたかの行や、お気に入りやブーストで再掲する投稿の、文字の大きさと余白を変えます。")
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
            } footer: {
                Text("投稿や通知、ユーザーのアイコン、リンク、ハッシュタグ、メディアをタップ、長押ししたときに、メニューを開くか、メニューのどの操作をするかを選びます。引用の囲みは投稿、リンクカードはリンク、Xの投稿の囲みはほかのサービスの投稿として扱います。ビューアの中は対象にしません。")
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
            } footer: {
                Text("投稿や通知、本文のリンクやハッシュタグ、メディアを長押ししたときのメニューに出す項目と、その並びを選びます。ユーザーのメニューは、投稿のメニューの中に、投稿したユーザーなどのサブメニューとして出るほか、本文のメンションを長押ししたときと、プロフィール画面の右上にも出ます。メディアのメニューは、サムネイルやプロフィールの画像を長押ししたときと、ビューアのメニューに出ます。ほかのサービスの投稿のメニューは、Xの投稿の囲みを長押ししたときに出ます。プロフィールの文章のメニューは、プロフィールの表示名、自己紹介、補足情報の行を長押ししたときに出ます。")
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
                Picker("公開範囲", selection: $settings.reblogVisibility) {
                    Text("アカウントの既定").tag(ReblogVisibility.accountDefault)
                    ForEach([(ReblogVisibility.public, Status.Visibility.public), (.unlisted, .unlisted), (.private, .private)], id: \.0) { reblogVisibility, visibility in
                        Text(VisibilityOption(visibility).title).tag(reblogVisibility)
                    }
                }
            } header: {
                Text("ブースト")
            } footer: {
                Text("メニューの「ブースト」でブーストするときの公開範囲です。「アカウントの既定」では、サーバーで設定した投稿の公開範囲でブーストします。フォロワーのみの自分の投稿は、この設定にかかわらずフォロワーのみでブーストします。ほかの公開範囲でブーストするときは、メニューの「公開範囲を選んでブースト」を使います。")
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
            } footer: {
                Text("隠すと、一覧を広く使えます。書くときは、右上のボタンで投稿欄を出します。書きかけの下書きや返信先があるときは、隠さずに表示します。\n畳まないと、書いていないときも投稿欄のボタンの行を出しておきます。押した投稿欄が広がって、ボタンの位置が動くことがなくなります。\n投稿欄のボタンでは、公開範囲、添付、注意書きのような項目を、投稿欄のボタンの行に常に出すか、＋の中に入れるかと、その並びを選びます。")
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
            } footer: {
                Text("添付するメディアを、送る前にこの大きさまで縮めて、通信量を減らします。この大きさに収まるメディアは、元のまま送ります。「縮めない」でも、サーバーの上限を超えるメディアは、上限に合わせて縮めます。")
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
            } footer: {
                Text("HDRで撮った写真や動画を、どれくらいの明るさで表示するかを選びます。「控えめなHDR」は、まわりのボタンや文字と並んでも眩しすぎないよう明るさを抑えます。「HDR」は、画面の明るさの上限まで使います。")
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
        } header: {
            Text("ステータスバーの通知")
        } footer: {
            if isAvailable {
                Text("通知を、画面の上のステータスバーの場所に1件ずつ流します。押すと通知のタブを開きます。通知のタブを見ている間は流しません。")
            } else {
                Text("このiPhoneでは使えません。この機種の画面の上端の形をまだ調べていないため、ステータスバーの場所に合わせて描けません。")
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
