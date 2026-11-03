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
    /// 設定を閉じ、ホームの上でアプリ内のSafariの高さを選ぶシートを出す。
    let openInAppBrowserHeight: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    /// 一覧から重ねて開いた画面。
    @State private var path: [SettingsPage]

    init(
        settings: AppSettings,
        instance: URL,
        account: String,
        diagnostics: ConnectionDiagnostics,
        tabIcons: ProfileTabIcons,
        lists: SettingsListActions,
        openInAppBrowserHeight: @escaping @MainActor () -> Void,
        opening page: SettingsPage? = nil
    ) {
        self.settings = settings
        self.instance = instance
        self.account = account
        self.diagnostics = diagnostics
        self.tabIcons = tabIcons
        self.lists = lists
        self.openInAppBrowserHeight = openInAppBrowserHeight
        _path = State(initialValue: page?.path ?? [])
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
                    NavigationLink(value: SettingsPage.tabs) {
                        SettingsCategoryLabel("タブ", systemImage: "menubar.dock.rectangle", color: .blue)
                    }
                } header: {
                    Text(account)
                }
                Section {
                    NavigationLink(value: SettingsPage.display) {
                        SettingsCategoryLabel("表示", systemImage: "textformat.size", color: .blue)
                    }
                    NavigationLink(value: SettingsPage.interaction) {
                        SettingsCategoryLabel("操作", systemImage: "hand.tap.fill", color: .orange)
                    }
                    NavigationLink(value: SettingsPage.compose) {
                        SettingsCategoryLabel("投稿欄", systemImage: "square.and.pencil", color: .green)
                    }
                    NavigationLink(value: SettingsPage.media) {
                        SettingsCategoryLabel("メディア", systemImage: "photo.fill", color: .red)
                    }
                    NavigationLink(value: SettingsPage.appIcon) {
                        AppIconSettingsLabel()
                    }
                }
                Section {
                    NavigationLink(value: SettingsPage.storage) {
                        SettingsCategoryLabel("ストレージ", systemImage: "internaldrive.fill", color: .gray)
                    }
                    NavigationLink(value: SettingsPage.about) {
                        SettingsCategoryLabel("情報", systemImage: "info.circle.fill", color: .gray)
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
                itemDeletion: MenuLayoutItemDeletion(canDelete: { $0.isList || $0.isUserAdded }) { item in
                    if case .list(let id, let title) = item {
                        lists.delete(id, title)
                    } else if item.isUserAdded {
                        // サーバーには何も残っていないので、確かめずに並びから外す。プロフィールなどの右上のメニューの「タブから外す」と同じ。
                        // 並びの画面の書き込み（`tabLayoutBinding`）は、最初の並びに戻したときのために、使う人が足した項目を残すので通さない。
                        settings.setTabLayout(settings.tabLayout(for: account).removing(item), for: account)
                    }
                }
            )
        case .statusActions: ObjectActionsSettingsView(entity: .status, settings: settings, menu: .statusMenu)
        case .notificationActions: ObjectActionsSettingsView(entity: .notification, settings: settings, menu: nil)
        case .userActions: ObjectActionsSettingsView(entity: .user, settings: settings, menu: .userMenu)
        case .linkActions: ObjectActionsSettingsView(entity: .link, settings: settings, menu: .linkMenu)
        case .externalPostActions: ObjectActionsSettingsView(entity: .externalPost, settings: settings, menu: .externalPostMenu)
        case .hashtagActions: ObjectActionsSettingsView(entity: .hashtag, settings: settings, menu: .hashtagMenu)
        case .mediaActions: ObjectActionsSettingsView(entity: .media, settings: settings, menu: .mediaMenu)
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
    ///   - openInAppBrowserHeight: 設定を閉じ、ホームの上でアプリ内のSafariの高さを選ぶシートを出す。
    ///   - page: 一覧から重ねて開いておく画面。
    ///   - onShownChange: 設定の画面が出たときにtrue、消えたときにfalseで呼ぶ。
    func presentSettings(instance: URL, account: String, diagnostics: ConnectionDiagnostics, tabIcons: ProfileTabIcons, lists: SettingsListActions, openInAppBrowserHeight: @escaping @MainActor () -> Void, opening page: SettingsPage? = nil, onShownChange: @escaping (Bool) -> Void) {
        let view = SettingsView(settings: AppDependencies.settings, instance: instance, account: account, diagnostics: diagnostics, tabIcons: tabIcons, lists: lists, openInAppBrowserHeight: openInAppBrowserHeight, opening: page)
        present(SettingsHostingController(rootView: view, onShownChange: onShownChange), animated: true)
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

/// 設定の画面を載せ、出たときと消えたときを1回ずつ知らせる。設定の画面の上に重ねたシートが出ている間は、まだ出ている扱いにする。
/// スワイプして閉じるのを途中でやめると、消えないまま`viewWillAppear`がもう一度呼ばれるので、出ているかを持って、変わったときだけ知らせる。
private final class SettingsHostingController: UIHostingController<SettingsView> {
    private let onShownChange: (Bool) -> Void
    private var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            onShownChange(isShown)
        }
    }

    init(rootView: SettingsView, onShownChange: @escaping (Bool) -> Void) {
        self.onShownChange = onShownChange
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
