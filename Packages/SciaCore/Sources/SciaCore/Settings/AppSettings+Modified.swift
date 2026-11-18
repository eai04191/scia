/// 設定の画面の行と画面ごとに、読んでいるプリセットが変えたかと、親のプリセットの値へ戻すこと（docs/preset.mdの「既定値から変えた項目」）。
/// 行と画面がプリセットのどの値を変えるかは、ここにまとめる。分類の画面は、その中の画面と行をまとめて見る。
extension SettingsItem {
    /// 行が変える値をプリセットに持つか。持たない行には、プリセットに含めないことを示す（docs/preset.md）。
    @MainActor
    public var isInPreset: Bool {
        !AppSettings.keys(of: self).isEmpty
    }
}

extension AppSettings {
    /// 行が変える値を、読んでいるプリセットが変えたか。プリセットに含めない値の行は、いつもfalse。
    public func isModified(_ item: SettingsItem) -> Bool {
        Self.keys(of: item).contains(where: isModified(key:))
    }

    /// 行が変える値を、親のプリセットの値に従わせる。
    public func reset(_ item: SettingsItem) {
        reset(keys: Self.keys(of: item))
    }

    /// 画面とその中の画面が変える値のどれかを、読んでいるプリセットが変えたか。
    public func isModified(_ page: SettingsPage) -> Bool {
        Self.keys(of: page).contains(where: isModified(key:))
    }

    /// 画面とその中の画面が変える値を、すべて親のプリセットの値に従わせる。
    public func reset(_ page: SettingsPage) {
        reset(keys: Self.keys(of: page))
    }

    /// 対象の操作の画面の、タップか長押しの割り当てを、読んでいるプリセットが変えたか。
    public func isModified(_ trigger: ObjectTrigger, on page: SettingsPage) -> Bool {
        Self.actionsKey(of: page).map { isModified(key: Self.key(of: trigger, in: $0)) } ?? false
    }

    /// 対象の操作の画面の、タップか長押しの割り当てを、親のプリセットの値に従わせる。
    public func reset(_ trigger: ObjectTrigger, on page: SettingsPage) {
        guard let key = Self.actionsKey(of: page) else { return }
        reset(keys: [Self.key(of: trigger, in: key)])
    }

    /// 自動翻訳の画面の設定を、読んでいるプリセットが変えたか。
    public func isModified(_ setting: AutoTranslationSetting) -> Bool {
        isModified(key: Self.key(of: setting))
    }

    public func reset(_ setting: AutoTranslationSetting) {
        reset(keys: [Self.key(of: setting)])
    }

    static func key(of setting: AutoTranslationSetting) -> String {
        switch setting {
        case .enabled: Keys.isAutoTranslationEnabled
        case .target: Keys.autoTranslationTarget
        }
    }

    /// 対象の操作の画面のスイッチを、読んでいるプリセットが変えたか。
    public func isModified(_ toggle: ObjectActionsScreen.Toggle) -> Bool {
        isModified(key: Self.key(of: toggle))
    }

    public func reset(_ toggle: ObjectActionsScreen.Toggle) {
        reset(keys: [Self.key(of: toggle)])
    }

    static func key(of toggle: ObjectActionsScreen.Toggle) -> String {
        switch toggle {
        case .actionBarItemsInMenu: Keys.showsActionBarItemsInMenu
        case .actionBarLongPressItemsInMenu: Keys.showsActionBarLongPressItemsInMenu
        }
    }

    static func key(of trigger: ObjectTrigger, in actionsKey: String) -> String {
        switch trigger {
        case .tap: "\(actionsKey).tap"
        case .longPress: "\(actionsKey).longPress"
        }
    }

    static func keys(of item: SettingsItem) -> [String] {
        switch item {
        case .accentColor: [Keys.accentColor]
        case .insertionMotion: [Keys.insertionMotion]
        case .statusBarTicker: [Keys.showsStatusBarTicker]
        case .linkBrowser: [Keys.linkBrowser]
        case .inAppBrowserHeight: [Keys.inAppBrowserSpaceAbove, Keys.opensInAppBrowserFullScreen]
        case .reblogVisibility: [Keys.reblogVisibility]
        case .composeBarIdle: [Keys.hidesEmptyComposeBar, Keys.keepsComposeBarOpen]
        case .imageUploadSize: [Keys.imageUploadSize]
        case .videoUploadSize: [Keys.videoUploadSize]
        case .mediaDynamicRange: [Keys.mediaDynamicRange]
        case .viewerMediaDynamicRange: [Keys.viewerMediaDynamicRange]
        case .originalThumbnailsOnExpensiveNetwork: [Keys.usesOriginalThumbnailsOnExpensiveNetwork]
        case .expandsXPosts: [Keys.expandsXPosts]
        case .profilePinned: [Keys.separatesProfilePinned]
        case .profileFeaturedTags: [Keys.showsProfileFeaturedTags]
        case .profileEndorsements: [Keys.showsProfileEndorsements]
        case .profileNoteLength: [Keys.profileNoteLength]
        case .dynamicProfileAccent: [Keys.usesDynamicProfileAccent]
        // プリセットに含めない値と、値を変えない行。
        case .ignoresUselessAltText, .version, .build, .branch, .commit, .builtAt, .sourceCode, .privacyPolicy: []
        }
    }

    static func keys(of page: SettingsPage) -> [String] {
        let own: [String] = switch page {
        case .appearance:
            AppearanceCatalog.values.map(appearanceKey) + AppearanceStorage.fieldNames.map(AppearanceStorage.key)
        case .notificationAppearance: NotificationAppearanceCatalog.values.map(appearanceKey)
        case .autoTranslation: AutoTranslationSetting.allCases.map(key(of:))
        case .statusMenu: [Keys.statusMenuLayout]
        case .statusActionBar: [Keys.postActionBarLayout]
        case .statusLeadingSwipe: [Keys.postLeadingSwipeLayout]
        case .statusTrailingSwipe: [Keys.postTrailingSwipeLayout]
        case .userMenu: [Keys.userMenuLayout]
        case .linkMenu: [Keys.linkMenuLayout]
        case .externalPostMenu: [Keys.externalPostMenuLayout]
        case .profileTextMenu: [Keys.profileTextMenuLayout]
        case .customEmojiMenu: [Keys.customEmojiMenuLayout]
        case .hashtagMenu: [Keys.hashtagMenuLayout]
        case .mediaMenu: [Keys.mediaMenuLayout]
        case .reactionMenu: [Keys.reactionMenuLayout]
        case .composeTools: [Keys.composeToolLayout]
        case .statusActions: ObjectActionsScreen.Toggle.allCases.map(key(of:))
        default: []
        }
        let actions = actionsKey(of: page).map { [key(of: .tap, in: $0), key(of: .longPress, in: $0)] } ?? []
        let items = (page.sections ?? []).flatMap(\.rows).flatMap { row -> [String] in
            switch row {
            case .item(let item): keys(of: item)
            case .page(let child): keys(of: child)
            }
        }
        let screens = ObjectActionsScreen(page).map { screen in
            ([screen.menu, screen.actionBar].compactMap(\.self) + screen.swipes.map(\.page)).flatMap(keys(of:))
        } ?? []
        return own + actions + items + screens
    }

    /// 対象の操作の画面の、タップと長押しの割り当てのキー。
    static func actionsKey(of page: SettingsPage) -> String? {
        switch page {
        case .statusActions: Keys.statusActions
        case .quotedStatusActions: Keys.quotedStatusActions
        case .notificationActions: Keys.notificationActions
        case .userActions: Keys.userActions
        case .linkActions: Keys.linkActions
        case .externalPostActions: Keys.externalPostActions
        case .hashtagActions: Keys.hashtagActions
        case .reactionActions: Keys.reactionActions
        case .mediaActions: Keys.mediaActions
        default: nil
        }
    }
}

/// 自動翻訳の画面で、プリセットに持つ設定。行ごとに点を付けて戻せるようにする。訳す言語と翻訳モードはプリセットに含めない（docs/preset.md）。
public enum AutoTranslationSetting: CaseIterable, Sendable {
    /// `AppSettings.isAutoTranslationEnabled`。
    case enabled
    /// `AppSettings.autoTranslationTarget`。
    case target
}
