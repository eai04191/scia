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
    let tabSources: SettingsTabSourceActions
    /// アカウントの画面に出すものと、押したときの処理。
    let accountScreen: AccountScreenContext
    /// 設定を閉じ、ホームの上でアプリ内のSafariの高さを選ぶシートを出す。
    let openInAppBrowserHeight: @MainActor () -> Void
    /// 謝辞の画面で、設定の画面を閉じて、ハンドルの人のプロフィールを開く。
    let openProfile: @MainActor (_ acct: String) -> Void
    /// トップの画面にいるかを、載せている側（`SettingsHostingController`）へ伝える。
    let navigation: SettingsNavigationState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    /// 設定のトップの画面から重ねて開いた画面。
    @State private var path: [SettingsPage]
    /// 開いたときに「投稿の見た目」か「通知の見た目」の上に重ねておく分類の画面。一度重ねたら、戻ってまた開いても重ねないよう、消す。
    @State private var appearanceGroup: AppearanceGroup.ID?

    init(
        settings: AppSettings,
        instance: URL,
        account: String,
        diagnostics: ConnectionDiagnostics,
        tabIcons: ProfileTabIcons,
        tabSources: SettingsTabSourceActions,
        accountScreen: AccountScreenContext,
        openInAppBrowserHeight: @escaping @MainActor () -> Void,
        openProfile: @escaping @MainActor (_ acct: String) -> Void,
        navigation: SettingsNavigationState,
        opening page: SettingsPage? = nil,
        appearanceGroup: AppearanceGroup.ID? = nil
    ) {
        self.settings = settings
        self.instance = instance
        self.account = account
        self.diagnostics = diagnostics
        self.tabIcons = tabIcons
        self.tabSources = tabSources
        self.accountScreen = accountScreen
        self.openInAppBrowserHeight = openInAppBrowserHeight
        self.openProfile = openProfile
        self.navigation = navigation
        _path = State(initialValue: page?.path ?? [])
        _appearanceGroup = State(initialValue: page == .appearance || page == .notificationAppearance ? appearanceGroup : nil)
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
                    NavigationLink(value: SettingsPage.account) {
                        SettingsCategoryLabel("アカウント", systemImage: "person.crop.circle.fill", color: .systemBlue)
                    }
                    NavigationLink(value: SettingsPage.tabs) {
                        SettingsCategoryLabel("タブ", systemImage: "dock.rectangle", color: .systemBlue)
                    }
                } header: {
                    Text(account)
                }
                Section {
                    NavigationLink(value: SettingsPage.display) {
                        SettingsCategoryLabel("表示", systemImage: "circle.lefthalf.filled", color: .systemBlue)
                    }
                    NavigationLink(value: SettingsPage.interaction) {
                        SettingsCategoryLabel("操作", systemImage: "hand.tap.fill", color: .systemOrange)
                    }
                    NavigationLink(value: SettingsPage.compose) {
                        SettingsCategoryLabel("作成", systemImage: "square.and.pencil", color: .systemGreen)
                    }
                    NavigationLink(value: SettingsPage.appIcon) {
                        AppIconSettingsLabel()
                    }
                }
                Section {
                    NavigationLink(value: SettingsPage.storage) {
                        SettingsCategoryLabel("ストレージ", systemImage: "externaldrive.fill", color: .systemGray)
                    }
                    NavigationLink(value: SettingsPage.about) {
                        SettingsCategoryLabel("情報", systemImage: "doc.text.fill", color: .systemGray)
                    }
                }
            }
            .topEdgeEffectHiddenOnMac()
            .navigationDestination(for: SettingsPage.self) { destination($0) }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .onChange(of: path, initial: true) { navigation.isAtRoot = path.isEmpty }
    }

    @ViewBuilder
    private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .display: DisplaySettingsView(settings: settings)
        case .interaction: InteractionSettingsView(settings: settings, openInAppBrowserHeight: openInAppBrowserHeight)
        case .compose: ComposeSettingsView(settings: settings)
        case .media: MediaSettingsView(settings: settings)
        case .about: AboutSettingsView()
        case .appIcon: AppIconSettingsView()
        case .account: AccountView(settings: settings, account: account, context: accountScreen)
        case .appearance:
            AppearanceEditorView(settings: settings, opening: appearanceGroup)
                .onAppear { appearanceGroup = nil }
        case .notificationAppearance:
            NotificationAppearanceEditorView(settings: settings, opening: appearanceGroup)
                .onAppear { appearanceGroup = nil }
        case .linkLoading: LinkLoadingSettingsView(settings: settings)
        case .autoTranslation:
            if #available(iOS 26.4, *) {
                AutoTranslationSettingsView(settings: settings)
            }
        case .tabs:
            MenuLayoutSettingsView(
                title: "タブ",
                layout: tabLayoutBinding,
                image: { [tabIcons] in tabIcons.icon(for: $0)?.menu },
                imageRevision: { [tabIcons] in tabIcons.revision },
                options: [MenuLayoutOption(
                    title: "メニューに“カスタマイズ”を表示",
                    footer: "切り替えタブのメニューに、この画面を開く“カスタマイズ”を表示します。",
                    isOn: $settings.showsTabMenuCustomize
                )],
                actions: [MenuLayoutAction(title: "リストを作成", symbolName: "plus", handler: tabSources.createList)],
                itemDeletion: MenuLayoutItemDeletion(canDelete: { $0.isList || $0.isUserAdded }) { item in
                    if case .list(let id, let title) = item {
                        tabSources.deleteList(id, title)
                    } else if item.isUserAdded {
                        // サーバーには何も残っていないので、確かめずに並びから外す。プロフィールなどの右上のメニューの「タブから外す」と同じ。
                        // 並びの画面の書き込み（`tabLayoutBinding`）は、最初の並びに戻したときのために、使う人が足した項目を残すので通さない。
                        settings.setTabLayout(settings.tabLayout(for: account).removing(item), for: account)
                    }
                }
            )
        case .statusActions:
            ObjectActionsSettingsView(
                entity: .status,
                settings: settings,
                menu: .statusMenu,
                actionBar: .statusActionBar,
                swipes: PostSwipeSettingsSection(leading: settings.postLeadingSwipeLayout, trailing: settings.postTrailingSwipeLayout),
                toggles: SettingsToggleSection(
                    header: "アクションバーを表示している投稿のメニュー",
                    toggles: [
                        .init(title: "アクションバーにある項目を表示", isOn: $settings.showsActionBarItemsInMenu),
                        .init(title: "ブーストとお気に入りの長押しの項目を表示", isOn: $settings.showsActionBarLongPressItemsInMenu),
                    ]
                )
            )
        case .quotedStatusActions: ObjectActionsSettingsView(entity: .quotedStatus, settings: settings, menu: nil)
        case .notificationActions: ObjectActionsSettingsView(entity: .notification, settings: settings, menu: nil)
        case .userActions: ObjectActionsSettingsView(entity: .user, settings: settings, menu: .userMenu)
        case .linkActions: ObjectActionsSettingsView(entity: .link, settings: settings, menu: .linkMenu)
        case .externalPostActions: ObjectActionsSettingsView(entity: .externalPost, settings: settings, menu: .externalPostMenu)
        case .hashtagActions: ObjectActionsSettingsView(entity: .hashtag, settings: settings, menu: .hashtagMenu)
        case .reactionActions: ObjectActionsSettingsView(entity: .reaction, settings: settings, menu: .reactionMenu)
        case .mediaActions: ObjectActionsSettingsView(entity: .media, settings: settings, menu: .mediaMenu)
        case .statusMenu: MenuLayoutSettingsView(title: "投稿のメニュー", layout: $settings.statusMenuLayout)
        case .statusActionBar: MenuLayoutSettingsView(title: "アクションバー", layout: $settings.postActionBarLayout)
        case .statusLeadingSwipe: MenuLayoutSettingsView(title: PostSwipeSettingsSection.title(of: .leading, in: layoutDirection), layout: $settings.postLeadingSwipeLayout)
        case .statusTrailingSwipe: MenuLayoutSettingsView(title: PostSwipeSettingsSection.title(of: .trailing, in: layoutDirection), layout: $settings.postTrailingSwipeLayout)
        case .userMenu: MenuLayoutSettingsView(title: "ユーザーのメニュー", layout: $settings.userMenuLayout)
        case .linkMenu: MenuLayoutSettingsView(title: "リンクのメニュー", layout: $settings.linkMenuLayout)
        case .externalPostMenu: MenuLayoutSettingsView(title: "ほかのサービスの投稿のメニュー", layout: $settings.externalPostMenuLayout)
        case .profileTextMenu: MenuLayoutSettingsView(title: "プロフィールの文章のメニュー", layout: $settings.profileTextMenuLayout)
        case .hashtagMenu: MenuLayoutSettingsView(title: "ハッシュタグのメニュー", layout: $settings.hashtagMenuLayout)
        case .reactionMenu: MenuLayoutSettingsView(title: "リアクションのメニュー", layout: $settings.reactionMenuLayout)
        case .mediaMenu: MenuLayoutSettingsView(title: "メディアのメニュー", layout: $settings.mediaMenuLayout)
        case .composeTools: MenuLayoutSettingsView(title: "投稿欄のボタン", layout: $settings.composeToolLayout)
        case .connection: ConnectionStatusView(instance: instance, diagnostics: diagnostics)
        case .connectionTimelines: StreamingTimelinesView(diagnostics: diagnostics, listTitles: listTitles)
        case .storage: StorageView()
        case .viewedMediaCache: MediaCacheView(category: .mediaFiles, actions: StorageView.Actions.app.mediaFiles)
        case .prefetchedMediaCache: MediaCacheView(category: .mediaPrefetch, actions: StorageView.Actions.app.mediaPrefetch)
        case .licenses: LicensesView()
        case .acknowledgments: AcknowledgmentsView(openProfile: openProfile)
        }
    }
}

/// タブの並びの画面で、リストを作る、消す。決まりはdocs/lists.mdにある。セッションが作る。
struct SettingsTabSourceActions {
    /// 名前を入れるアラートを出して作る。
    let createList: @MainActor () -> Void
    /// 確かめてから消す。
    let deleteList: @MainActor (_ id: String, _ title: String) -> Void
}

extension UIViewController {
    /// 設定の画面を、この画面から重ねた画面のうち、いちばん手前の画面に重ねて出す。
    /// - Parameters:
    ///   - instance: ログイン中のアカウントのサーバー。
    ///   - diagnostics: 「接続の状態」画面に出す、ログイン中のアカウントの接続の状態。
    ///   - tabIcons: タブの並びで、タブに置いたプロフィールに出すその人のアイコン。
    ///   - tabSources: タブの並びでリストを作る、消す。
    ///   - accountScreen: アカウントの画面に出すものと、押したときの処理。
    ///   - openInAppBrowserHeight: 設定を閉じ、ホームの上でアプリ内のSafariの高さを選ぶシートを出す。
    ///   - openProfile: 謝辞の画面で、設定の画面を閉じて、ハンドルの人のプロフィールを開く。
    ///   - page: 設定のトップの画面から重ねて開いておく画面。
    ///   - appearanceGroup: `page`が「投稿の見た目」か「通知の見た目」のとき、その上に重ねておく分類の画面。
    ///   - onShownChange: 設定の画面が出たときにtrue、消えたときにfalseで呼ぶ。
    func presentSettings(instance: URL, account: String, diagnostics: ConnectionDiagnostics, tabIcons: ProfileTabIcons, tabSources: SettingsTabSourceActions, accountScreen: AccountScreenContext, openInAppBrowserHeight: @escaping @MainActor () -> Void, openProfile: @escaping @MainActor (_ acct: String) -> Void, opening page: SettingsPage? = nil, appearanceGroup: AppearanceGroup.ID? = nil, onShownChange: @escaping (Bool) -> Void) {
        let navigation = SettingsNavigationState()
        let view = SettingsView(settings: AppDependencies.settings, instance: instance, account: account, diagnostics: diagnostics, tabIcons: tabIcons, tabSources: tabSources, accountScreen: accountScreen, openInAppBrowserHeight: openInAppBrowserHeight, openProfile: openProfile, navigation: navigation, opening: page, appearanceGroup: appearanceGroup)
        presentOnFrontmost(SettingsHostingController(rootView: view, navigation: navigation, onShownChange: onShownChange))
    }

    /// メニューの「カスタマイズ」から、その並びの設定の画面を、設定のトップの画面に重ねて開く。決まりはdocs/menus.mdの「並びの設定」にある。
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

/// 設定がトップの画面にいるか。SwiftUIの画面が書き、載せている側がスワイプして閉じてよいかを決めるのに読む。
@MainActor
final class SettingsNavigationState {
    var isAtRoot = true
}

/// 設定の画面を載せ、出たときと消えたときを1回ずつ知らせる。設定の画面の上に重ねたシートが出ている間は、まだ出ている扱いにする。
/// スワイプして閉じるのを途中でやめると、消えないまま`viewWillAppear`がもう一度呼ばれるので、出ているかを持って、変わったときだけ知らせる。
private final class SettingsHostingController: UIHostingController<SettingsView> {
    private let navigation: SettingsNavigationState
    private let onShownChange: (Bool) -> Void
    /// 最後に指を置いた位置（このビューの座標）。下へのスワイプで閉じてよいかを、指を置いた場所で決める。
    private var touchDownLocation: CGPoint?
    private var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            onShownChange(isShown)
        }
    }

    init(rootView: SettingsView, navigation: SettingsNavigationState, onShownChange: @escaping (Bool) -> Void) {
        self.navigation = navigation
        self.onShownChange = onShownChange
        super.init(rootView: rootView)
        presentationController?.delegate = self
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let touchObserver = UITapGestureRecognizer()
        touchObserver.delegate = self
        view.addGestureRecognizer(touchObserver)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isShown = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isShown = false
    }
}

extension SettingsHostingController: UIAdaptivePresentationControllerDelegate {
    /// トップの画面では、本文から下へスワイプしても閉じる。閉じるために、画面の上まで指を伸ばさなくて済むようにするため。
    /// 中の画面では、ナビゲーションバーから下へスワイプしたときだけ閉じる。一覧を上へ戻すスクロールの勢いで閉じてしまうため。
    /// スクロールビューのない画面（読み込み中や空の表示）でも同じにするため、指を置いた位置で見分ける。
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        if navigation.isAtRoot { return true }
        guard let touchDownLocation, let bar = view.visibleNavigationBar else { return false }
        return touchDownLocation.y <= bar.convert(bar.bounds, to: view).maxY
    }
}

extension SettingsHostingController: UIGestureRecognizerDelegate {
    /// 指を置いた位置を覚えるだけで、ほかの操作の邪魔をしないよう、ジェスチャーには触れたものを渡さない。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touchDownLocation = touch.location(in: view)
        return false
    }
}

private extension UIView {
    /// 窓にある、隠していないナビゲーションバー。
    var visibleNavigationBar: UINavigationBar? {
        if let bar = self as? UINavigationBar, bar.window != nil, !bar.isHidden {
            return bar
        }
        return subviews.lazy.compactMap(\.visibleNavigationBar).first
    }
}
