import Foundation

/// 設定の画面に何を、どの順で、どんな名前で並べるか。どのUIも同じ並びと名前にするため、UIはセクションと行を上から順に描くだけにする。
/// 行の見た目（スイッチ、選択、値の行）と、分類の行に添える記号と色は、UIが決める。
public struct SettingsSection: Hashable, Sendable {
    public var header: String?
    /// セクションの下の説明。Markdownのリンクを含むことがある。
    public var footer: String?
    public var rows: [SettingsRow]

    public init(header: String? = nil, footer: String? = nil, rows: [SettingsRow]) {
        self.header = header
        self.footer = footer
        self.rows = rows
    }
}

public enum SettingsRow: Hashable, Sendable {
    /// ほかの設定の画面へ入る行。行の名前は`SettingsPage.rowTitle`。
    case page(SettingsPage)
    /// その場で値を変えるか、値を見せる行。
    case item(SettingsItem)

    public var title: String {
        switch self {
        case .page(let page): page.rowTitle
        case .item(let item): item.title
        }
    }
}

/// 設定の画面に並べる、画面へ入る行のほかの行。値は`AppSettings`の同じ名前の設定で、選択肢の名前は値の型の`title`にある。
public enum SettingsItem: String, CaseIterable, Hashable, Sendable {
    // 表示
    /// `AppSettings.accentColor`。選択肢は`AccentColorChoice`。
    case accentColor
    /// `AppSettings.insertionMotion`。選択肢は`InsertionMotion`。
    case insertionMotion
    /// `AppSettings.showsStatusBarTicker`。画面の上端に通知を流す場所のないUIでは、オフにして無効にするか、行を出さない。
    case statusBarTicker

    // 操作
    /// `AppSettings.linkBrowser`。選択肢は`LinkBrowser`。
    case linkBrowser
    /// `AppSettings.inAppBrowserHeight`と`opensInAppBrowserFullScreen`。値を選ぶのは別の画面で、行には今の値を出す。
    case inAppBrowserHeight
    /// `AppSettings.reblogVisibility`。選択肢は`ReblogVisibility`。
    case reblogVisibility

    // 作成
    /// `AppSettings.composeBarIdle`。選択肢は`ComposeBarIdle`。
    case composeBarIdle
    /// `AppSettings.imageUploadSize`。選択肢は`ImageUploadSize`。
    case imageUploadSize
    /// `AppSettings.videoUploadSize`。選択肢は`VideoUploadSize`。
    case videoUploadSize

    // メディア
    /// `AppSettings.mediaDynamicRange`。選択肢は`MediaDynamicRange`。
    case mediaDynamicRange
    /// `AppSettings.viewerMediaDynamicRange`。選択肢は`MediaDynamicRange`。
    case viewerMediaDynamicRange
    /// `AppSettings.usesOriginalThumbnailsOnExpensiveNetwork`。
    case originalThumbnailsOnExpensiveNetwork
    /// `AppSettings.ignoresUselessAltText`。
    case ignoresUselessAltText

    // プロフィール
    /// `AppSettings.profileNoteLength`。選択肢は`ProfileNoteLength`。
    case profileNoteLength
    /// `AppSettings.separatesProfilePinned`。
    case profilePinned
    /// `AppSettings.showsProfileFeaturedTags`。
    case profileFeaturedTags
    /// `AppSettings.showsProfileEndorsements`。
    case profileEndorsements
    /// `AppSettings.usesDynamicProfileAccent`。
    case dynamicProfileAccent

    // リンク先の読み込み
    /// `AppSettings.expandsXPosts`。
    case expandsXPosts

    // 情報。値はUIがビルドの情報から出す。
    case version
    case build
    case branch
    case commit
    case builtAt
    /// リポジトリを開くリンク。行き先は`Config/app-info.json`の値で、UIが持つ。
    case sourceCode
    /// プライバシーポリシーを開くリンク。行き先は`Config/app-info.json`の値で、UIが持つ。
    case privacyPolicy

    public var title: String {
        switch self {
        case .accentColor: "アクセントカラー"
        case .insertionMotion: "最上部での新着の挿入"
        case .statusBarTicker: "通知をステータスバーに流す"
        case .linkBrowser: "開く場所"
        case .inAppBrowserHeight: "シートの高さ"
        case .reblogVisibility: "公開範囲"
        case .composeBarIdle: "書いていないとき"
        case .imageUploadSize: "画像"
        case .videoUploadSize: "動画"
        case .mediaDynamicRange: "アプリ"
        case .viewerMediaDynamicRange: "ビューア"
        case .originalThumbnailsOnExpensiveNetwork: "高画質のサムネイル"
        case .ignoresUselessAltText: "仮の代替テキストを無視"
        case .profileNoteLength: "自己紹介"
        case .profilePinned: "固定された投稿を分けて表示"
        case .profileFeaturedTags: "注目のハッシュタグを表示"
        case .profileEndorsements: "紹介しているユーザーを表示"
        case .dynamicProfileAccent: "アイコンのカラーに合わせる"
        case .expandsXPosts: "Xの投稿を展開"
        case .version: "バージョン"
        case .build: "ビルド"
        case .branch: "ブランチ"
        case .commit: "commit"
        case .builtAt: "ビルド日時"
        case .sourceCode: "ソースコード"
        case .privacyPolicy: "プライバシーポリシー"
        }
    }
}

extension SettingsItem {
    /// `settings`で、この行を設定の画面に出すか。シートの高さは、リンクをアプリ内のSafariのシートで開くときだけ使う。
    @MainActor
    public func isShown(in settings: AppSettings) -> Bool {
        switch self {
        case .inAppBrowserHeight: settings.linkBrowser == .inApp
        default: true
        }
    }

    /// アプリ内のSafariの高さの行に出す今の値。
    @MainActor
    public static func inAppBrowserHeightValue(in settings: AppSettings) -> String {
        settings.opensInAppBrowserFullScreen ? "全画面" : settings.inAppBrowserHeight.title
    }
}

extension SettingsPage {
    /// 設定のトップの画面の題。
    public static let rootTitle = "設定"

    /// 設定のトップの画面。最初のセクションは、選んでいるアカウントのための設定で、見出しにそのアカウントのハンドルを出す。
    public static func rootSections(handle: String) -> [SettingsSection] {
        [
            SettingsSection(header: handle, rows: [.page(.account), .page(.tabs)]),
            SettingsSection(rows: [.page(.accountManagement)]),
            SettingsSection(rows: [.page(.presets)]),
            SettingsSection(rows: [.page(.display), .page(.interaction), .page(.compose), .page(.appIcon)]),
            SettingsSection(rows: [.page(.storage), .page(.about)]),
        ]
    }

    /// 画面の題。
    /// - Parameter isRightToLeft: 右から左へ書く言語で描いている。スワイプの向きの名前を入れ替える。
    public func title(isRightToLeft: Bool = false) -> String {
        switch self {
        case .display: "表示"
        case .interaction: "操作"
        case .compose: "作成"
        case .media: "メディア"
        case .profile: "プロフィール"
        case .about: "情報"
        case .appIcon: "アプリのアイコン"
        case .presets: "プリセット"
        case .accountPreset: "アカウントのプリセット"
        case .appPreset: "アプリのプリセット"
        case .presetEditor: "プリセットを編集"
        case .presetComparison: SettingsTexts.Presets.compare
        case .presetManagement: SettingsTexts.Presets.manage
        case .appearance: "投稿"
        case .notificationAppearance: "通知"
        case .linkLoading: "リンク先の読み込み"
        case .autoTranslation: "自動翻訳"
        case .customEmojis: "表示を変更したカスタム絵文字"
        case .userDisplays: "表示を変更したユーザー"
        case .tabs: "タブ"
        case .account: "アカウント"
        case .accountManagement: "アカウントを管理"
        case .statusActions: "投稿"
        case .quotedStatusActions: "引用の投稿"
        case .notificationActions: "通知"
        case .userActions: "ユーザー"
        case .linkActions: "リンク"
        case .externalPostActions: "ほかのサービスの投稿"
        case .hashtagActions: "ハッシュタグ"
        case .mediaActions: "メディア"
        case .reactionActions: "リアクション"
        case .statusMenu: "投稿のメニュー"
        case .statusActionBar: "アクションバー"
        case .statusLeadingSwipe: PostSwipeSide.leading.title(isRightToLeft: isRightToLeft)
        case .statusTrailingSwipe: PostSwipeSide.trailing.title(isRightToLeft: isRightToLeft)
        case .userMenu: "ユーザーのメニュー"
        case .linkMenu: "リンクのメニュー"
        case .externalPostMenu: "ほかのサービスの投稿のメニュー"
        case .profileTextMenu: "プロフィールの文章のメニュー"
        case .customEmojiMenu: "カスタム絵文字のメニュー"
        case .hashtagMenu: "ハッシュタグのメニュー"
        case .mediaMenu: "メディアのメニュー"
        case .reactionMenu: "リアクションのメニュー"
        case .composeTools: "投稿欄のボタン"
        case .connection: "接続の状態"
        case .connectionTimelines: "受信中のタイムライン"
        case .storage: "ストレージ"
        case .viewedMediaCache: StorageBreakdown.Category.mediaFiles.title
        case .prefetchedMediaCache: StorageBreakdown.Category.mediaPrefetch.title
        case .licenses: "ライセンス"
        case .acknowledgments: "謝辞"
        }
    }

    /// 親の画面の行に出す名前。親の画面で何の設定か分かるものは、題より短く書く。
    public func rowTitle(isRightToLeft: Bool = false) -> String {
        switch self {
        case .statusMenu, .userMenu, .linkMenu, .externalPostMenu, .hashtagMenu, .mediaMenu, .reactionMenu: "メニュー"
        case .profileTextMenu: "プロフィールの文章"
        case .customEmojiMenu: "カスタム絵文字"
        case .viewedMediaCache: "表示済み"
        case .prefetchedMediaCache: "先読み"
        default: title(isRightToLeft: isRightToLeft)
        }
    }

    public var title: String { title() }
    public var rowTitle: String { rowTitle() }

    /// プリセットの値を変える画面か。「表示」「操作」「作成」と、その中の画面。プリセットに含めない値だけを並べる画面は除く。
    public var changesPresetValues: Bool {
        guard self != .customEmojis, self != .userDisplays, let first = path.first else { return false }
        return [.display, .interaction, .compose].contains(first)
    }

    /// 画面に並べるセクション。並びが決まっている画面だけが返す。
    /// 見た目の選択肢と数値を並べる画面（`appearance`、`notificationAppearance`）は`AppearanceGroup`と`AppearanceChoices`に、
    /// 対象の操作の画面は`ObjectActionsScreen`に、項目を並べ替える画面は`MenuLayout`に、ストレージは`StorageBreakdown`と`StorageRemoveTarget`にある。
    ///
    /// UIが出せない行（OSの版で使えない自動翻訳など）は、UIが除く。除いて空になったセクションは出さない。
    public var sections: [SettingsSection]? {
        switch self {
        case .display:
            [
                SettingsSection(header: "外観", rows: [.page(.appearance), .page(.notificationAppearance), .page(.media), .page(.profile), .item(.accentColor)]),
                SettingsSection(footer: "“自動”では“視差効果を減らす”がオンのときはアニメーションしません。", rows: [.item(.insertionMotion)]),
                SettingsSection(rows: [.item(.statusBarTicker)]),
                SettingsSection(rows: [.page(.linkLoading), .page(.autoTranslation)]),
                SettingsSection(rows: [.page(.customEmojis), .page(.userDisplays)]),
            ]
        case .interaction:
            [
                SettingsSection(rows: [
                    .page(.statusActions), .page(.quotedStatusActions), .page(.notificationActions), .page(.userActions), .page(.linkActions),
                    .page(.externalPostActions), .page(.hashtagActions), .page(.mediaActions), .page(.reactionActions), .page(.profileTextMenu), .page(.customEmojiMenu),
                ]),
                SettingsSection(header: "リンク", rows: [.item(.linkBrowser), .item(.inAppBrowserHeight)]),
                SettingsSection(header: "ブースト", rows: [.item(.reblogVisibility)]),
            ]
        case .compose:
            [
                SettingsSection(rows: [.item(.composeBarIdle), .page(.composeTools)]),
                SettingsSection(header: "送る前に縮める", rows: [.item(.imageUploadSize), .item(.videoUploadSize)]),
            ]
        case .media:
            [
                SettingsSection(header: "HDRのメディアの明るさ", rows: [.item(.mediaDynamicRange), .item(.viewerMediaDynamicRange)]),
                SettingsSection(header: "モバイル通信", rows: [.item(.originalThumbnailsOnExpensiveNetwork)]),
                SettingsSection(footer: "投稿したアプリが自動で付けたと思われる説明にならない代替テキストをないものとして扱います。", rows: [.item(.ignoresUselessAltText)]),
            ]
        case .profile:
            [
                SettingsSection(rows: [.item(.profileNoteLength)]),
                SettingsSection(rows: [.item(.profilePinned), .item(.profileFeaturedTags), .item(.profileEndorsements)]),
                SettingsSection(rows: [.item(.dynamicProfileAccent)]),
            ]
        case .linkLoading:
            // 送り先、届くもの、通信のきっかけを、オンにする前に読めるように書く。同意はこの説明で取り、オンにするときに確認は重ねない（docs/link-card.md）。
            [SettingsSection(footer: """
            Xの投稿へのリンクを引用のように表示します。

            オンにすると、Xの投稿へのリンクを含む投稿を表示するたびにfxtwitter（Sciaと無関係な外部サービス）へ問い合わせ、アイコンやメディアをXから読み込みます。IPアドレスや表示した投稿がfxtwitterとXに伝わり、通信量も増えます。

            [fxtwitterのプライバシーについて](https://docs.fxembed.com/guide/faq/)
            """, rows: [.item(.expandsXPosts)])]
        case .about:
            [
                SettingsSection(rows: [.item(.version), .item(.build), .item(.branch), .item(.commit), .item(.builtAt)]),
                SettingsSection(rows: [.page(.connection), .page(.licenses), .page(.acknowledgments)]),
                SettingsSection(rows: [.item(.sourceCode), .item(.privacyPolicy)]),
            ]
        case .appIcon, .appearance, .notificationAppearance, .autoTranslation, .customEmojis, .userDisplays, .tabs, .account, .accountManagement, .statusActions, .quotedStatusActions, .notificationActions,
             .userActions, .linkActions, .externalPostActions, .hashtagActions, .mediaActions, .reactionActions, .statusMenu, .statusActionBar,
             .statusLeadingSwipe, .statusTrailingSwipe, .userMenu, .linkMenu, .externalPostMenu, .profileTextMenu, .customEmojiMenu, .hashtagMenu, .mediaMenu, .reactionMenu,
             .composeTools, .connection, .connectionTimelines, .storage, .viewedMediaCache, .prefetchedMediaCache, .licenses, .acknowledgments,
             .presets, .appPreset, .accountPreset, .presetManagement, .presetEditor, .presetComparison:
            nil
        }
    }
}

/// 投稿のどちらの側のスワイプか。先頭の側は右にスワイプ、末尾の側は左にスワイプで出す（右から左へ書く言語では逆）。
public enum PostSwipeSide: Hashable, Sendable {
    case leading
    case trailing

    /// この側のボタンの並びの設定の画面。
    public var page: SettingsPage {
        switch self {
        case .leading: .statusLeadingSwipe
        case .trailing: .statusTrailingSwipe
        }
    }

    /// この側のボタンの並び。
    @MainActor
    public func layout(in settings: AppSettings) -> MenuLayout<PostSwipeItem> {
        switch self {
        case .leading: settings.postLeadingSwipeLayout
        case .trailing: settings.postTrailingSwipeLayout
        }
    }

    /// iOSのメールの「スワイプオプション」と同じ名前。先頭の側は、左から右へ書く言語では右にスワイプして出す。
    public func title(isRightToLeft: Bool) -> String {
        switch (self, isRightToLeft) {
        case (.leading, false), (.trailing, true): "右にスワイプ"
        default: "左にスワイプ"
        }
    }
}

extension MenuLayout where Item == PostSwipeItem {
    /// 投稿の操作の画面の、スワイプの行の値。割り当てた項目の名前を並べる。
    public var swipeSummary: TextLists.ItemList {
        swipeItems.isEmpty ? TextLists.ItemList(single: "なし") : TextLists.items(swipeItems.map(\.title))
    }
}

/// 1つの対象の操作の画面（`statusActions`など）に並べるもの。決まりはdocs/object-actions.mdの「設定画面」にある。
///
/// 上から、タップと長押しの選択のセクション、メニューとアクションバーの並びの画面へ入るセクション、左右のスワイプのセクション、スイッチのセクションを並べる。持たないセクションは出さない。
/// 選択は、先頭の欄に「メニューを開く」、その対象の主な操作（`ObjectActionItem.primaryItem`）、アクションバーを持つ対象では「アクションバーを開く」を、
/// 次の欄に残りのメニューの項目を、既定の並び（`MenuItemKind.defaultLayout`）の順で、メニューと同じ名前とアイコンで並べる。
public struct ObjectActionsScreen: Hashable, Sendable {
    public static let tapTitle = "タップ"
    public static let longPressTitle = "長押し"
    public static let openMenuTitle = "メニューを開く"
    public static let openMenuSymbolName = "contextualmenu.and.cursorarrow"
    /// スイッチのセクションの見出し。
    public static let toggleHeader = "アクションバーを表示している投稿のメニュー"

    /// 画面。
    public let page: SettingsPage
    /// この対象のメニューの並びの画面。引用の投稿と通知は投稿のメニューを出し、自分のメニューを持たないのでnil。
    public let menu: SettingsPage?
    /// アクションバーのボタンの並びの画面。アクションバーを出せる対象（投稿）だけが持ち、持つ対象では「アクションバーを開く」も選べる。
    public let actionBar: SettingsPage?
    /// 左右のスワイプの並びの画面へ入る行。投稿だけが持つ。
    public let swipes: [PostSwipeSide]
    /// スイッチのセクション。投稿では、アクションバーを出している投稿のメニューに何を出すかを置く。
    public let toggles: [Toggle]

    public enum Toggle: String, CaseIterable, Hashable, Sendable {
        /// `AppSettings.showsActionBarItemsInMenu`。
        case actionBarItemsInMenu
        /// `AppSettings.showsActionBarLongPressItemsInMenu`。
        case actionBarLongPressItemsInMenu

        public var title: String {
            switch self {
            case .actionBarItemsInMenu: "アクションバーにある項目を表示"
            case .actionBarLongPressItemsInMenu: "ブーストとお気に入りの長押しの項目を表示"
            }
        }
    }

    /// タップにも長押しにもメニューを選んでいないときに、選択のセクションの下に出す説明。
    public func noMenuFooter() -> String {
        "タップでも長押しでもメニューを開かないため、\(page.title)のメニューにしかない操作は使えません。"
    }

    /// `page`の画面に並べるもの。対象の操作の画面でなければnil。
    public init?(_ page: SettingsPage) {
        switch page {
        case .statusActions:
            self.init(page: page, menu: .statusMenu, actionBar: .statusActionBar, swipes: [.leading, .trailing], toggles: [.actionBarItemsInMenu, .actionBarLongPressItemsInMenu])
        case .quotedStatusActions, .notificationActions: self.init(page: page, menu: nil)
        case .userActions: self.init(page: page, menu: .userMenu)
        case .linkActions: self.init(page: page, menu: .linkMenu)
        case .externalPostActions: self.init(page: page, menu: .externalPostMenu)
        case .hashtagActions: self.init(page: page, menu: .hashtagMenu)
        case .reactionActions: self.init(page: page, menu: .reactionMenu)
        case .mediaActions: self.init(page: page, menu: .mediaMenu)
        default: return nil
        }
    }

    private init(page: SettingsPage, menu: SettingsPage?, actionBar: SettingsPage? = nil, swipes: [PostSwipeSide] = [], toggles: [Toggle] = []) {
        self.page = page
        self.menu = menu
        self.actionBar = actionBar
        self.swipes = swipes
        self.toggles = toggles
    }
}

extension MediaDynamicRange {
    /// 設定の選択肢の名前。
    public var title: String {
        switch self {
        case .standard: "SDR"
        case .constrainedHigh: "控えめなHDR"
        case .high: "HDR"
        }
    }
}
