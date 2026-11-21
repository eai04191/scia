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
    /// 今のウインドウでのタブバーの形。「タブ」の行のアイコンを、今の画面と同じ形にする。
    let tabBarShape: TabBarShapeModel
    /// アカウントの画面に出すものと、押したときの処理。
    let accountScreen: AccountScreenContext
    /// 「アカウントを管理」の画面に渡すもの。
    /// アカウントのリストを読めないとき（Keychainを読めないなど）はnil。
    let signedInAccountsContext: SignedInAccountsContext?
    /// 設定を閉じ、ホームの上でアプリ内のSafariの高さを選ぶシートを出す。
    let openInAppBrowserHeight: @MainActor (AppSettings) -> Void
    /// 謝辞の画面で、設定の画面を閉じて、ハンドルの人のプロフィールを開く。
    let openProfile: @MainActor (_ acct: String) -> Void
    /// トップの画面にいるかを、載せている側（`SettingsHostingController`）へ伝える。
    let openUserDisplay: @MainActor (String) -> Void
    let userDisplayLoader: UserDisplayLoader
    let navigation: SettingsNavigationState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    /// 設定のトップの画面から重ねて開いた画面。
    @State private var path: [SettingsPage]
    /// 開いたときに「投稿の見た目」か「通知の見た目」の上に重ねておく分類の画面。一度重ねたら、戻ってまた開いても重ねないよう、消す。
    @State private var appearanceGroup: AppearanceGroup.ID?
    /// 開いているアカウントが使っているプリセットを読み書きする設定。設定のトップの分類からは、これの値を変える（docs/preset.md）。
    let windowSettings: AppSettings
    /// 「プリセットを管理」から開いたプリセットの値を書く設定。nilなら`windowSettings`。プリセットの画面から戻ったらnilに戻す。
    @State private var editingSettings: AppSettings?

    init(
        settings: AppSettings,
        windowSettings: AppSettings,
        instance: URL,
        account: String,
        diagnostics: ConnectionDiagnostics,
        tabIcons: ProfileTabIcons,
        tabSources: SettingsTabSourceActions,
        tabBarShape: TabBarShapeModel,
        accountScreen: AccountScreenContext,
        signedInAccounts: SignedInAccountsContext?,
        openInAppBrowserHeight: @escaping @MainActor (AppSettings) -> Void,
        openProfile: @escaping @MainActor (_ acct: String) -> Void,
        openUserDisplay: @escaping @MainActor (String) -> Void,
        userDisplayLoader: UserDisplayLoader,
        navigation: SettingsNavigationState,
        opening page: SettingsPage? = nil,
        appearanceGroup: AppearanceGroup.ID? = nil,
        editing: AppSettings? = nil
    ) {
        self.settings = settings
        self.windowSettings = windowSettings
        self.instance = instance
        self.account = account
        self.diagnostics = diagnostics
        self.tabIcons = tabIcons
        self.tabSources = tabSources
        self.tabBarShape = tabBarShape
        self.accountScreen = accountScreen
        signedInAccountsContext = signedInAccounts
        self.openInAppBrowserHeight = openInAppBrowserHeight
        self.openProfile = openProfile
        self.openUserDisplay = openUserDisplay
        self.userDisplayLoader = userDisplayLoader
        self.navigation = navigation
        _editingSettings = State(initialValue: editing)
        // 「プリセットを管理」から開いたプリセットを直している途中にアプリ内のSafariの高さを選びに出たときは、戻ったときもそのプリセットの画面を挟む。
        // 挟まないと、次に画面を移ったときに直す先が開いているアカウントのプリセットに戻るため。
        if case .preset = editing?.target {
            _path = State(initialValue: SettingsPage.presetEditor.path + (page?.path ?? []))
        } else {
            _path = State(initialValue: page?.path ?? [])
        }
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
                ForEach(SettingsPage.rootSections(handle: account), id: \.self) { section in
                    SettingsFormSection(header: section.header, footer: section.footer) {
                        ForEach(section.rows, id: \.self) { row in
                            if case .page(let page) = row {
                                rootRow(page)
                            }
                        }
                    }
                }
            }
            .topEdgeEffectHiddenOnMac()
            .navigationDestination(for: SettingsPage.self) { destination($0) }
            .navigationTitle(SettingsPage.rootTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(SettingsTexts.done) { dismiss() }
                }
            }
        }
        .onChange(of: path, initial: true) {
            navigation.isAtRoot = path.isEmpty
            navigation.page = path.last
        }
        .onChange(of: path) {
            // プリセットの画面から戻ったら、トップの分類はまた開いているアカウントのプリセットを直す。
            if !path.contains(.presetEditor) {
                editingSettings = nil
            }
        }
        .onChange(of: settings.store.observedLibrary) { _, library in
            // 編集しているプリセットが消されたら、書く先がないので、編集をやめて管理の画面に戻る。
            guard case .preset(let id) = editingSettings?.target, !library.contains(id) else { return }
            editingSettings = nil
            path = path.starts(with: SettingsPage.presetManagement.path) ? SettingsPage.presetManagement.path : []
        }
    }

    /// 値を変える画面で値を書く設定。
    private var current: AppSettings { editingSettings ?? windowSettings }

    private func rootRow(_ page: SettingsPage) -> some View {
        NavigationLink(value: page) {
            HStack {
                rootLabel(of: page)
                if let value = rootValue(of: page) {
                    Spacer(minLength: 8)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 管理の画面から、プリセットの画面を開く。プリセットの画面から開いたとき（複製したとき）は、その画面を替える。
    private func openPreset(_ id: PresetID) {
        editingSettings = settings.editing(id)
        if path.last != .presetEditor {
            path.append(.presetEditor)
        }
    }

    /// ログインしているアカウントのハンドル。アカウントの一覧を読めないとき（Keychainを読めないなど）は、開いているアカウントだけにする。
    /// 1つだけになるので、プリセットの画面にアカウントの行は出さない。
    private var signedInAccounts: [String] {
        (try? AppDependencies.accounts.get())?.accounts.map(\.handle) ?? [account]
    }

    /// トップの画面の行に添える今の値。「プリセット」の行に、開いているアカウントが使っているプリセットの名前を出す。
    private func rootValue(of page: SettingsPage) -> String? {
        let library = settings.store.observedLibrary
        switch page {
        case .presets: return library.name(of: library.preset(forAccount: account))
        default: return nil
        }
    }

    /// トップの画面の行のラベル。分類には、iPhoneの設定アプリと同じく、色を敷いた四角のアイコンを添える。
    @ViewBuilder
    private func rootLabel(of page: SettingsPage) -> some View {
        if page == .appIcon {
            AppIconSettingsLabel()
        } else {
            let icon = rootIcon(of: page)
            SettingsCategoryLabel(page.rowTitle, systemImage: icon.systemImage, color: icon.color)
        }
    }

    private func rootIcon(of page: SettingsPage) -> (systemImage: String, color: UIColor) {
        if page == .tabs { return (tabBarShape.shape.symbolName, .systemBlue) }
        return page.categoryIcon ?? ("gearshape.fill", .systemGray)
    }

    /// 値を変える画面には、サブタイトルに直しているプリセットを出す。
    @ViewBuilder
    private func destination(_ page: SettingsPage) -> some View {
        if page.changesPresetValues {
            screen(page)
                .presetEditingSubtitle(current)
        } else {
            screen(page)
        }
    }

    @ViewBuilder
    private func screen(_ page: SettingsPage) -> some View {
        switch page {
        case .display, .compose, .media, .profile, .linkLoading: SettingsScreenForm(page: page, settings: current)
        case .interaction: SettingsScreenForm(page: page, settings: current) { [current] in openInAppBrowserHeight(current) }
        case .about: AboutSettingsView()
        case .appIcon: AppIconSettingsView()
        case .account: AccountView(settings: settings, account: account, context: accountScreen)
        case .accountManagement:
            if let signedInAccountsContext {
                SignedInAccountsView(settings: windowSettings, context: signedInAccountsContext)
            }
        case .presets: PresetsView(settings: settings, accounts: signedInAccounts)
        case .presetManagement:
            PresetManagementView(settings: settings, openPreset: openPreset) {
                path.append(.presetComparison)
            }
        case .presetComparison: PresetComparisonView(settings: settings)
        case .appPreset: AppPresetView(settings: settings)
        case .accountPreset: AccountPresetView(settings: settings, account: account)
        case .presetEditor:
            if let editingSettings, case .preset(let id) = editingSettings.target {
                PresetEditorView(settings: editingSettings, preset: id, openPreset: openPreset)
                    .id(id)
            }
        case .appearance:
            AppearanceEditorView(settings: current, opening: appearanceGroup)
                .onAppear { appearanceGroup = nil }
        case .notificationAppearance:
            NotificationAppearanceEditorView(settings: current, opening: appearanceGroup)
                .onAppear { appearanceGroup = nil }
        case .customEmojis: CustomEmojiDisplaySettingsView(settings: current)
        case .userDisplays: UserDisplaySettingsView(settings: current, open: openUserDisplay, loader: userDisplayLoader)
        case .autoTranslation:
            if #available(iOS 26.4, *) {
                AutoTranslationSettingsView(settings: current)
            }
        case .tabs:
            MenuLayoutSettingsView(
                title: page.title,
                layout: tabLayoutBinding,
                image: { [tabIcons] in tabIcons.icon(for: $0)?.menu },
                imageRevision: { [tabIcons] in tabIcons.revision },
                options: [MenuLayoutOption(
                    title: SettingsTexts.Tabs.showsCustomize,
                    footer: SettingsTexts.Tabs.showsCustomizeFooter,
                    isOn: $settings.showsTabMenuCustomize
                )],
                actions: [MenuLayoutAction(title: SettingsTexts.createList, symbolName: "plus", handler: tabSources.createList)],
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
        case .statusActions: ObjectActionsSettingsView(entity: .status, settings: current)
        case .quotedStatusActions: ObjectActionsSettingsView(entity: .quotedStatus, settings: current)
        case .notificationActions: ObjectActionsSettingsView(entity: .notification, settings: current)
        case .userActions: ObjectActionsSettingsView(entity: .user, settings: current)
        case .linkActions: ObjectActionsSettingsView(entity: .link, settings: current)
        case .externalPostActions: ObjectActionsSettingsView(entity: .externalPost, settings: current)
        case .hashtagActions: ObjectActionsSettingsView(entity: .hashtag, settings: current)
        case .reactionActions: ObjectActionsSettingsView(entity: .reaction, settings: current)
        case .mediaActions: ObjectActionsSettingsView(entity: .media, settings: current)
        case .statusMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).statusMenuLayout, reset: { current.reset(page) })
        case .statusActionBar: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).postActionBarLayout, reset: { current.reset(page) })
        case .statusLeadingSwipe: MenuLayoutSettingsView(title: page.title(isRightToLeft: layoutDirection == .rightToLeft), layout: Bindable(current).postLeadingSwipeLayout, reset: { current.reset(page) })
        case .statusTrailingSwipe: MenuLayoutSettingsView(title: page.title(isRightToLeft: layoutDirection == .rightToLeft), layout: Bindable(current).postTrailingSwipeLayout, reset: { current.reset(page) })
        case .userMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).userMenuLayout, reset: { current.reset(page) })
        case .linkMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).linkMenuLayout, reset: { current.reset(page) })
        case .externalPostMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).externalPostMenuLayout, reset: { current.reset(page) })
        case .profileTextMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).profileTextMenuLayout, reset: { current.reset(page) })
        case .customEmojiMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).customEmojiMenuLayout, reset: { current.reset(page) })
        case .hashtagMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).hashtagMenuLayout, reset: { current.reset(page) })
        case .reactionMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).reactionMenuLayout, reset: { current.reset(page) })
        case .mediaMenu: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).mediaMenuLayout, reset: { current.reset(page) })
        case .composeTools: MenuLayoutSettingsView(title: page.title, layout: Bindable(current).composeToolLayout, reset: { current.reset(page) })
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

extension SettingsPage {
    /// トップの画面の分類の行に添えるアイコン。プリセットの画面の分類の行にも同じものを添える。タブの並びはタブバーの形で替わるので、ここには持たない。
    var categoryIcon: (systemImage: String, color: UIColor)? {
        switch self {
        case .account: ("person.crop.circle.fill", .systemBlue)
        case .accountManagement: ("person.2.fill", .systemGray)
        case .presets: ("square.stack.3d.up.fill", .systemPurple)
        case .display: ("circle.lefthalf.filled", .systemBlue)
        case .interaction: ("hand.tap.fill", .systemOrange)
        case .compose: ("square.and.pencil", .systemGreen)
        case .storage: ("externaldrive.fill", .systemGray)
        case .about: ("doc.text.fill", .systemGray)
        default: nil
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
    ///   - windowSettings: 開いているアカウントが使っているプリセットを読み書きする設定。設定のトップの分類からは、これの値を変える。
    ///   - instance: ログイン中のアカウントのサーバー。
    ///   - diagnostics: 「接続の状態」画面に出す、ログイン中のアカウントの接続の状態。
    ///   - tabIcons: タブの並びで、タブに置いたプロフィールに出すその人のアイコン。
    ///   - tabSources: タブの並びでリストを作る、消す。
    ///   - tabBarShape: 今のウインドウでのタブバーの形。
    ///   - accountScreen: アカウントの画面に出すものと、押したときの処理。
    ///   - signedInAccounts: 「アカウントを管理」の画面に渡すもの。
    ///   - openInAppBrowserHeight: 設定を閉じ、ホームの上でアプリ内のSafariの高さを選ぶシートを出す。
    ///   - openProfile: 謝辞の画面で、設定の画面を閉じて、ハンドルの人のプロフィールを開く。
    ///   - page: 設定のトップの画面から重ねて開いておく画面。
    ///   - appearanceGroup: `page`が「投稿の見た目」か「通知の見た目」のとき、その上に重ねておく分類の画面。
    ///   - onShownChange: 設定の画面が出たときにtrue、消えたときにfalseで呼ぶ。
    func presentSettings(windowSettings: AppSettings, instance: URL, account: String, diagnostics: ConnectionDiagnostics, tabIcons: ProfileTabIcons, tabSources: SettingsTabSourceActions, tabBarShape: TabBarShapeModel, accountScreen: AccountScreenContext, signedInAccounts: SignedInAccountsContext?, openInAppBrowserHeight: @escaping @MainActor (AppSettings) -> Void, openProfile: @escaping @MainActor (_ acct: String) -> Void, openUserDisplay: @escaping @MainActor (String, @escaping @MainActor () -> Bool) -> Void, userDisplayLoader: UserDisplayLoader, opening page: SettingsPage? = nil, appearanceGroup: AppearanceGroup.ID? = nil, editing: AppSettings? = nil, onShownChange: @escaping (Bool) -> Void) {
        let navigation = SettingsNavigationState()
        let view = SettingsView(settings: AppDependencies.settings, windowSettings: windowSettings, instance: instance, account: account, diagnostics: diagnostics, tabIcons: tabIcons, tabSources: tabSources, tabBarShape: tabBarShape, accountScreen: accountScreen, signedInAccounts: signedInAccounts, openInAppBrowserHeight: openInAppBrowserHeight, openProfile: openProfile, openUserDisplay: { acct in openUserDisplay(acct, { navigation.page == .userDisplays }) }, userDisplayLoader: userDisplayLoader, navigation: navigation, opening: page, appearanceGroup: appearanceGroup, editing: editing)
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
    var page: SettingsPage?
}

/// 設定の画面を載せ、出たときと消えたときを1回ずつ知らせる。設定の画面の上に重ねたシートが出ている間は、まだ出ている扱いにする。
/// スワイプして閉じるのを途中でやめると、消えないまま`viewWillAppear`がもう一度呼ばれるので、出ているかを持って、変わったときだけ知らせる。
/// 開いている間は、アプリ内通知のチップの列をシートの上へ出し、ナビゲーションバーのすぐ下に置く。
/// 組み込みのプリセットを複製して切り替えたこと（docs/preset.md）など、設定の中で起きたことの知らせが、シートに覆われて見えなくならないようにするため。
private final class SettingsHostingController: UIHostingController<SettingsView>, NoticeScreen {
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let overlay = NoticeOverlay.installed(in: view.window)
        overlay?.bringToFront()
        overlay?.update()
    }

    /// 大きなタイトルの伸び縮みや、中の画面への移動でナビゲーションバーの高さが変わったら、列をそのすぐ下へ置き直す。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isShown, !isBeingDismissed else { return }
        NoticeOverlay.installed(in: view.window)?.update()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        // 閉じ始めたら、列をシートの下へ戻す。閉じる途中のシートの上にチップが浮いたままにならないようにする。閉じるのをやめたら手前へ戻す。
        let window = view.window
        NoticeOverlay.installed(in: window)?.returnBelowPresentations()
        transitionCoordinator?.animate(alongsideTransition: nil) { context in
            guard context.isCancelled, let overlay = NoticeOverlay.installed(in: window) else { return }
            overlay.bringToFront()
            overlay.update()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isShown = false
    }

    func noticePlacement(below: CGFloat) -> NoticePlacement {
        guard let view = viewIfLoaded, view.window != nil, let bar = view.visibleNavigationBar else { return NoticePlacement(top: below) }
        return NoticePlacement(top: bar.convert(CGPoint(x: 0, y: bar.bounds.maxY + 8), to: nil).y)
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
