import SciaCore
import SwiftUI
import UIKit

/// 使う人が選ぶ設定の画面。
struct SettingsView: View {
    @Bindable var settings: AppSettings
    /// ログイン中のアカウントのサーバー。
    let instance: URL
    /// ログイン中のアカウントのハンドル。タブの並びはアカウントごとに持つ。
    let account: String
    let diagnostics: ConnectionDiagnostics
    @Environment(\.dismiss) private var dismiss
    /// 時刻の表記の見本に使う、3分前の日時。
    @State private var previewDate: Date
    /// コピーしたことを知らせる表示を戻すまでの時計。
    private let clock: any Clock<Duration>
    @State private var copiedBuildInfo = false
    @State private var appIconError: String?

    init(
        settings: AppSettings,
        instance: URL,
        account: String,
        diagnostics: ConnectionDiagnostics,
        now: () -> Date = AppDependencies.now,
        clock: any Clock<Duration> = AppDependencies.clock
    ) {
        self.settings = settings
        self.instance = instance
        self.account = account
        self.diagnostics = diagnostics
        _previewDate = State(initialValue: now().addingTimeInterval(-180))
        self.clock = clock
    }

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

    private var tabLayoutBinding: Binding<MenuLayout<TabItem>> {
        Binding {
            settings.tabLayout(for: account)
        } set: { layout in
            settings.setTabLayout(layout.keepingAccountHashtags(of: settings.tabLayout(for: account)), for: account)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PostPreview(
                        createdAt: previewDate,
                        nameStyle: settings.statusNameStyle,
                        timeStyle: settings.statusTimeStyle,
                        avatarShape: settings.avatarShape,
                        animatesAvatars: settings.animatesAvatars,
                        linkCardThumbnailSide: settings.linkCardThumbnailSide,
                        glyphLanguage: settings.glyphLanguage,
                        emojiStyle: settings.emojiStyle,
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
                } header: {
                    Text("プレビュー")
                }
                Section {
                    Picker("名前の表記", selection: $settings.statusNameStyle) {
                        Text("名前、ハンドル").tag(StatusNameStyle.nameAndAcct)
                        Text("名前").tag(StatusNameStyle.nameOnly)
                        Text("ハンドル").tag(StatusNameStyle.acctOnly)
                        Text("ハンドル、名前").tag(StatusNameStyle.acctAndName)
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
                    Toggle("カスタム絵文字のアニメーションを再生する", isOn: $settings.animatesCustomEmojis)
                    Picker("リンクカードの画像の位置", selection: $settings.linkCardThumbnailSide) {
                        Text("左").tag(LinkCardThumbnailSide.left)
                        Text("右").tag(LinkCardThumbnailSide.right)
                    }
                    Picker("漢字の字形", selection: $settings.glyphLanguage) {
                        Text("自動").tag(GlyphLanguage.automatic)
                        Text("日本語").tag(GlyphLanguage.japanese)
                        Text("簡体字中国語").tag(GlyphLanguage.simplifiedChinese)
                        Text("繁体字中国語").tag(GlyphLanguage.traditionalChinese)
                        Text("韓国語").tag(GlyphLanguage.korean)
                    }
                    Picker("絵文字", selection: $settings.emojiStyle) {
                        Text("Apple").tag(EmojiStyle.system)
                        Text("Twemoji").tag(EmojiStyle.twemoji)
                    }
                } header: {
                    Text("投稿の表示")
                } footer: {
                    Text("相対時刻では、1週間より前の投稿は日付で表示します。\n漢字の字形は、言語の付いていない投稿や名前で使います。投稿に日本語・中国語・韓国語の言語が付いていれば、その言語の字形で表示します。「自動」では、iPhoneの言語の一覧で最初の日本語・中国語・韓国語に従い、どれもなければ日本語にします。")
                }
                Section {
                    PostPreview(
                        createdAt: previewDate,
                        nameStyle: settings.statusNameStyle,
                        timeStyle: settings.statusTimeStyle,
                        avatarShape: settings.avatarShape,
                        animatesAvatars: settings.animatesAvatars,
                        linkCardThumbnailSide: settings.linkCardThumbnailSide,
                        glyphLanguage: settings.glyphLanguage,
                        emojiStyle: settings.emojiStyle,
                        showsReactions: true,
                        drawsReactionGlowInHDR: settings.drawsReactionGlowInHDR,
                        builder: PostContentBuilder(
                            tuning: AppDependencies.tuning,
                            settings: settings,
                            emojiImages: AppDependencies.emojiImages,
                            mediaImages: AppDependencies.mediaImages,
                            avatarImages: AppDependencies.avatarImages
                        )
                    )
                    .listRowInsets(EdgeInsets())
                    // タイムラインと同じく、光の下の端を区切りにする。区切り線が光に重なると、光が灰色に濁って見えるため。
                    .listRowSeparator(.hidden, edges: .bottom)
                    Toggle("HDRで光らせる", isOn: $settings.drawsReactionGlowInHDR)
                } header: {
                    Text("お気に入りとブーストの光")
                } footer: {
                    Text("お気に入りやブーストをした投稿の下の端の光を、HDRに対応した画面では白より明るく表示します。オフにすると、ほかの表示と同じ明るさにします。HDRのメディアの明るさの設定とは別に選べます。")
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
                Section {
                    NavigationLink("タブ") {
                        MenuLayoutSettingsView(title: "タブ", layout: tabLayoutBinding)
                    }
                } header: {
                    Text("タブ")
                } footer: {
                    Text("タブバーに並べるタイムラインと、その並びを選びます。「切り替えタブ」より下に置いたものは、タブバーの最後のタブにまとめ、見出しのメニューで切り替えます。並びは\(account)のものです。")
                }
                Section {
                    NavigationLink("投稿のメニュー") {
                        MenuLayoutSettingsView(title: "投稿のメニュー", layout: $settings.statusMenuLayout)
                    }
                    NavigationLink("ユーザーのメニュー") {
                        MenuLayoutSettingsView(title: "ユーザーのメニュー", layout: $settings.userMenuLayout)
                    }
                    NavigationLink("リンクのメニュー") {
                        MenuLayoutSettingsView(title: "リンクのメニュー", layout: $settings.linkMenuLayout)
                    }
                    NavigationLink("ハッシュタグのメニュー") {
                        MenuLayoutSettingsView(title: "ハッシュタグのメニュー", layout: $settings.hashtagMenuLayout)
                    }
                    NavigationLink("メディアのメニュー") {
                        MenuLayoutSettingsView(title: "メディアのメニュー", layout: $settings.mediaMenuLayout)
                    }
                } header: {
                    Text("長押しのメニュー")
                } footer: {
                    Text("投稿や通知、本文のリンクやハッシュタグ、メディアを長押ししたときのメニューに出す項目と、その並びを選びます。ユーザーのメニューは、投稿のメニューの中に、投稿したユーザーなどのサブメニューとして出るほか、本文のメンションを長押ししたときと、プロフィール画面の右上にも出ます。メディアのメニューは、サムネイルやプロフィールの画像を長押ししたときと、ビューアのメニューに出ます。")
                }
                Section {
                    Toggle("書いていないときは隠す", isOn: $settings.hidesEmptyComposeBar)
                    NavigationLink("投稿欄のボタン") {
                        MenuLayoutSettingsView(title: "投稿欄のボタン", layout: $settings.composeToolLayout)
                    }
                } header: {
                    Text("投稿欄")
                } footer: {
                    Text("隠すと、一覧を広く使えます。書くときは、右上のボタンで投稿欄を出します。書きかけの下書きや返信先があるときは、隠さずに表示します。\n投稿欄のボタンでは、公開範囲、添付、注意書きのような項目を、投稿欄のボタンの行に常に出すか、＋の中に入れるかと、その並びを選びます。")
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
                    NavigationLink("ライセンス") {
                        LicensesView()
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
                        try? await clock.sleep(for: .seconds(1.5))
                        copiedBuildInfo = false
                    }
                }
            }
            .topEdgeEffectHiddenOnMac()
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

extension UIViewController {
    /// - Parameters:
    ///   - instance: ログイン中のアカウントのサーバー。
    ///   - diagnostics: 「接続の状態」画面に出す、ログイン中のアカウントの接続の状態。
    func presentSettings(instance: URL, account: String, diagnostics: ConnectionDiagnostics) {
        let view = SettingsView(settings: AppDependencies.settings, instance: instance, account: account, diagnostics: diagnostics)
        present(UIHostingController(rootView: view), animated: true)
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
