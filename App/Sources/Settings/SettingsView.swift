import os
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
    /// タブの並びで、タブに置いたプロフィールに出すその人のアイコン。
    let tabIcons: ProfileTabIcons
    /// タブの並びでリストを作る、消す。
    let lists: SettingsListActions
    @Environment(\.dismiss) private var dismiss
    /// 時刻の表記の見本に使う、3分前の日時。
    @State private var previewDate: Date
    /// コピーしたことを知らせる表示を戻すまでの時計。
    private let clock: any Clock<Duration>
    @State private var copiedBuildInfo = false
    @State private var appIconError: String?
    /// 一覧から重ねて開いた画面。
    @State private var path: [SettingsPage]

    init(
        settings: AppSettings,
        instance: URL,
        account: String,
        diagnostics: ConnectionDiagnostics,
        tabIcons: ProfileTabIcons,
        lists: SettingsListActions,
        opening page: SettingsPage? = nil,
        now: () -> Date = AppDependencies.now,
        clock: any Clock<Duration> = AppDependencies.clock
    ) {
        self.settings = settings
        self.instance = instance
        self.account = account
        self.diagnostics = diagnostics
        self.tabIcons = tabIcons
        self.lists = lists
        _previewDate = State(initialValue: now().addingTimeInterval(-180))
        _path = State(initialValue: page?.path ?? [])
        self.clock = clock
    }

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

    private var tabLayoutBinding: Binding<MenuLayout<TabItem>> {
        Binding {
            settings.tabLayout(for: account)
        } set: { layout in
            settings.setTabLayout(layout.keepingUserAddedItems(of: settings.tabLayout(for: account)), for: account)
        }
    }

    /// 接続の状態の画面で、購読しているリストに名前を出すためのもの。
    private var listTitles: [String: String] {
        var titles: [String: String] = [:]
        for case .item(.list(let id, let title), _) in settings.tabLayout(for: account).elements {
            titles[id] = title
        }
        return titles
    }

    var body: some View {
        NavigationStack(path: $path) {
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
                    NavigationLink("タブ", value: SettingsPage.tabs)
                } header: {
                    Text("タブ")
                } footer: {
                    Text("タブバーに並べるタイムラインと、その並びを選びます。「切り替えタブ」より下に置いたものは、タブバーの最後のタブにまとめ、見出しのメニューで切り替えます。並びは\(account)のものです。")
                }
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
                    Toggle("書いていないときは隠す", isOn: $settings.hidesEmptyComposeBar)
                    Toggle("書いていないときも畳まない", isOn: $settings.keepsComposeBarOpen)
                    NavigationLink("投稿欄のボタン", value: SettingsPage.composeTools)
                } header: {
                    Text("投稿欄")
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
                    NavigationLink("接続の状態", value: SettingsPage.connection)
                    NavigationLink("ストレージ", value: SettingsPage.storage)
                    NavigationLink("ライセンス", value: SettingsPage.licenses)
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
                    .task(.withoutRequests, id: copiedBuildInfo) {
                        guard copiedBuildInfo else { return }
                        try? await clock.sleep(for: .seconds(1.5))
                        copiedBuildInfo = false
                    }
                }
            }
            .topEdgeEffectHiddenOnMac()
            .navigationDestination(for: SettingsPage.self) { destination($0) }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .appearance: AppearanceEditorView(settings: settings)
        case .notificationAppearance: NotificationAppearanceEditorView(settings: settings)
        case .tabs:
            MenuLayoutSettingsView(
                title: "タブ",
                layout: tabLayoutBinding,
                image: { [tabIcons] in tabIcons.icon(for: $0)?.menu },
                imageRevision: { [tabIcons] in tabIcons.revision },
                options: [MenuLayoutOption(
                    title: "メニューに「カスタマイズ」を表示",
                    footer: "タブバーの最後のタブにまとめた項目を切り替えるメニューに、この画面を開く「カスタマイズ」を出します。",
                    isOn: $settings.showsTabMenuCustomize
                )],
                actions: [MenuLayoutAction(title: "リストを作成", symbolName: "plus", handler: lists.create)],
                itemDeletion: MenuLayoutItemDeletion(
                    canDelete: { $0.isList || $0.isUserAdded },
                    footer: "リストと、プロフィールなどの画面から追加したタブは、左へスワイプすると削除できます。"
                ) { item in
                    if case .list(let id, let title) = item {
                        lists.delete(id, title)
                    } else if item.isUserAdded {
                        // サーバーには何も残っていないので、確かめずに並びから外す。プロフィールなどの右上のメニューの「タブから外す」と同じ。
                        // 並びの画面の書き込み（`tabLayoutBinding`）は、最初の並びに戻したときのために、使う人が足した項目を残すので通さない。
                        settings.setTabLayout(settings.tabLayout(for: account).removing(item), for: account)
                    }
                }
            )
        case .statusActions: ObjectActionsSettingsView(entity: .status, settings: settings)
        case .notificationActions: ObjectActionsSettingsView(entity: .notification, settings: settings)
        case .userActions: ObjectActionsSettingsView(entity: .user, settings: settings)
        case .linkActions: ObjectActionsSettingsView(entity: .link, settings: settings)
        case .externalPostActions: ObjectActionsSettingsView(entity: .externalPost, settings: settings)
        case .hashtagActions: ObjectActionsSettingsView(entity: .hashtag, settings: settings)
        case .mediaActions: ObjectActionsSettingsView(entity: .media, settings: settings)
        case .statusMenu: MenuLayoutSettingsView(title: "投稿のメニュー", layout: $settings.statusMenuLayout)
        case .userMenu: MenuLayoutSettingsView(title: "ユーザーのメニュー", layout: $settings.userMenuLayout)
        case .linkMenu: MenuLayoutSettingsView(title: "リンクのメニュー", layout: $settings.linkMenuLayout)
        case .externalPostMenu: MenuLayoutSettingsView(title: "ほかのサービスの投稿のメニュー", layout: $settings.externalPostMenuLayout)
        case .profileTextMenu: MenuLayoutSettingsView(title: "プロフィールの文章のメニュー", layout: $settings.profileTextMenuLayout)
        case .hashtagMenu: MenuLayoutSettingsView(title: "ハッシュタグのメニュー", layout: $settings.hashtagMenuLayout)
        case .mediaMenu: MenuLayoutSettingsView(title: "メディアのメニュー", layout: $settings.mediaMenuLayout)
        case .composeTools: MenuLayoutSettingsView(title: "投稿欄のボタン", layout: $settings.composeToolLayout)
        case .connection: ConnectionStatusView(instance: instance, diagnostics: diagnostics, listTitles: listTitles)
        case .storage: StorageView()
        case .viewedMediaCache: MediaCacheView(category: .mediaFiles, actions: StorageView.Actions.app.mediaFiles)
        case .prefetchedMediaCache: MediaCacheView(category: .mediaPrefetch, actions: StorageView.Actions.app.mediaPrefetch)
        case .licenses: LicensesView()
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

/// タブの並びの画面で、リストを作る、消す。決まりはdocs/lists.mdにある。セッションが作る。
struct SettingsListActions {
    /// 名前を入れるアラートを出して作る。
    let create: @MainActor () -> Void
    /// 確かめてから消す。
    let delete: @MainActor (_ id: String, _ title: String) -> Void
}

extension UIViewController {
    /// - Parameters:
    ///   - instance: ログイン中のアカウントのサーバー。
    ///   - diagnostics: 「接続の状態」画面に出す、ログイン中のアカウントの接続の状態。
    ///   - tabIcons: タブの並びで、タブに置いたプロフィールに出すその人のアイコン。
    ///   - lists: タブの並びでリストを作る、消す。
    ///   - page: 一覧から重ねて開いておく画面。
    func presentSettings(instance: URL, account: String, diagnostics: ConnectionDiagnostics, tabIcons: ProfileTabIcons, lists: SettingsListActions, opening page: SettingsPage? = nil) {
        let view = SettingsView(settings: AppDependencies.settings, instance: instance, account: account, diagnostics: diagnostics, tabIcons: tabIcons, lists: lists, opening: page)
        present(UIHostingController(rootView: view), animated: true)
    }

    /// メニューの「カスタマイズ」から、その並びの設定の画面を、設定の一覧に重ねて開く。決まりはdocs/menus.mdの「並びの設定」にある。
    /// `scia://settings/<画面>`と同じ入り口を通し、この画面を出している窓のセッションで開く。
    /// Macでメディアを別のウインドウに開いたビューアは、窓にセッションを持たない（`MediaWindowSceneDelegate`）ため、押しても開かずにerrorのログだけ残す。
    /// Macでしか起きず、別の窓のセッションへ届ける経路を足す手間に見合わないため、扱わない。
    func openMenuSettings(_ page: SettingsPage) {
        guard let delegate = viewIfLoaded?.window?.windowScene?.delegate as? SceneDelegate else {
            settingsLogger.error("menu settings ignored without scene: \(page.rawValue, privacy: .public)")
            return
        }
        delegate.open(.settings(page))
    }
}

private let settingsLogger = SciaLog.logger(category: "settings")

/// HDRのメディアの明るさの選択肢。ビューア以外とビューアで同じものを並べる。
private struct MediaDynamicRangeOptions: View {
    var body: some View {
        Text("SDR").tag(MediaDynamicRange.standard)
        Text("控えめなHDR").tag(MediaDynamicRange.constrainedHigh)
        Text("HDR").tag(MediaDynamicRange.high)
    }
}
