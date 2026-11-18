import Foundation

/// プリセットより前の版が端末に1つずつ持っていた設定を、プリセットに移す（docs/preset.mdの「前の版からの移行」）。
/// プリセットをまだ持っていない端末で、前の版のキーが1つでもあれば、標準を親にした「移行した設定」を作ってアプリのプリセットにし、標準と違う値だけを書く。移したキーは消す。
@MainActor
enum LegacySettingsMigration {
    static func migrate(into app: AppSettings, defaults: UserDefaults) {
        guard defaults.object(forKey: presetsKey) == nil, Keys.all.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        // 値を1つ書くたびにプリセットを保存するので、途中で終わると、次の起動ではプリセットがあって移行を飛ばし、残りの値が移らない。
        // そのため、保存しない一時の保存先で値を揃えてから、プリセットを1回で書く。
        // 一時の保存先は、同時に移す別の保存先（並べて走るテスト）と重ならないよう、保存先ごとに分ける。
        let suite = "\(scratchSuitePrefix).\(UInt(bitPattern: ObjectIdentifier(app.store).hashValue))"
        guard let scratch = UserDefaults(suiteName: suite) else { return }
        scratch.removePersistentDomain(forName: suite)
        defer { scratch.removePersistentDomain(forName: suite) }
        let draft = AppSettings(store: SettingsStore(defaults: scratch, keepsComposeBarOpenByDefault: app.store.keepsComposeBarOpenByDefault), target: .scope(.app))
        var created: PresetID?
        draft.store.updateLibrary { library throws(PresetError) in
            let id = try library.create(parent: .builtIn(.standard), name: SettingsTexts.Presets.migratedName)
            try library.select(id, for: .app)
            created = id
        }
        guard let created else { return }
        write(Reader(defaults: defaults), into: draft.editing(created))
        let migrated = draft.store.library
        app.store.updateLibrary { $0 = migrated }
        for key in Keys.all {
            defaults.removeObject(forKey: key)
        }
    }

    private static let presetsKey = "settings.presets"
    private static let scratchSuitePrefix = "net.mizle.scia.legacySettingsMigration"

    // 1項目ずつ、前の版の読み方で読み、標準と違えば書く。
    // swiftlint:disable:next function_body_length
    private static func write(_ old: Reader, into settings: AppSettings) {
        settings.migrate(\.usesOriginalThumbnailsOnExpensiveNetwork, old.bool(Keys.usesOriginalThumbnailsOnExpensiveNetwork))
        settings.migrate(\.ignoresUselessAltText, old.bool(Keys.ignoresUselessAltText))
        settings.migrate(\.showsStatusBarTicker, old.bool(Keys.showsStatusBarTicker))
        settings.migrate(\.expandsXPosts, old.bool(Keys.expandsXPosts))
        settings.migrate(\.usesDynamicProfileAccent, old.bool(Keys.usesDynamicProfileAccent))
        settings.migrate(\.separatesProfilePinned, old.bool(Keys.separatesProfilePinned))
        settings.migrate(\.showsProfileFeaturedTags, old.bool(Keys.showsProfileFeaturedTags))
        settings.migrate(\.showsProfileEndorsements, old.bool(Keys.showsProfileEndorsements))
        settings.migrate(\.profileNoteLength, old.raw(Keys.profileNoteLength))
        settings.migrate(\.isAutoTranslationEnabled, old.bool(Keys.isAutoTranslationEnabled))
        if let target = old.string(Keys.autoTranslationTarget) {
            settings.migrate(\.autoTranslationTarget, .some(target))
        }
        if let data = old.data(Keys.appearanceChoices) {
            settings.appearance = AppearanceChoices(stored: data)
        }
        settings.migrate(\.insertionMotion, old.raw(Keys.insertionMotion))
        settings.migrate(\.accentColor, old.raw(Keys.accentColor))
        settings.migrate(\.linkBrowser, old.raw(Keys.linkBrowser))
        if let space = old.double(Keys.inAppBrowserSpaceAbove), space.isFinite {
            settings.migrate(\.inAppBrowserHeight, InAppBrowserHeight(spaceAbove: space))
        }
        settings.migrate(\.opensInAppBrowserFullScreen, old.bool(Keys.opensInAppBrowserFullScreen))
        settings.migrate(\.reblogVisibility, old.raw(Keys.reblogVisibility))
        settings.migrate(\.statusMenuLayout, old.layout(Keys.statusMenuLayout))
        settings.migrate(\.userMenuLayout, old.layout(Keys.userMenuLayout))
        settings.migrate(\.linkMenuLayout, old.layout(Keys.linkMenuLayout))
        settings.migrate(\.externalPostMenuLayout, old.layout(Keys.externalPostMenuLayout))
        settings.migrate(\.profileTextMenuLayout, old.layout(Keys.profileTextMenuLayout))
        settings.migrate(\.customEmojiMenuLayout, old.layout(Keys.customEmojiMenuLayout))
        settings.migrate(\.hashtagMenuLayout, old.layout(Keys.hashtagMenuLayout))
        settings.migrate(\.reactionMenuLayout, old.layout(Keys.reactionMenuLayout))
        settings.migrate(\.mediaMenuLayout, old.layout(Keys.mediaMenuLayout))
        settings.migrate(\.composeToolLayout, old.layout(Keys.composeToolLayout))
        settings.migrate(\.postActionBarLayout, old.layout(Keys.postActionBarLayout))
        settings.migrate(\.postLeadingSwipeLayout, old.layout(Keys.postLeadingSwipeLayout))
        settings.migrate(\.postTrailingSwipeLayout, old.layout(Keys.postTrailingSwipeLayout))
        settings.migrate(\.showsActionBarItemsInMenu, old.bool(Keys.showsActionBarItemsInMenu))
        settings.migrate(\.showsActionBarLongPressItemsInMenu, old.bool(Keys.showsActionBarLongPressItemsInMenu))
        settings.migrate(\.statusActions, old.actions(Keys.statusActions))
        settings.migrate(\.quotedStatusActions, old.actions(Keys.quotedStatusActions))
        settings.migrate(\.notificationActions, old.actions(Keys.notificationActions))
        settings.migrate(\.userActions, old.actions(Keys.userActions))
        settings.migrate(\.linkActions, old.actions(Keys.linkActions))
        settings.migrate(\.externalPostActions, old.actions(Keys.externalPostActions))
        settings.migrate(\.hashtagActions, old.actions(Keys.hashtagActions))
        settings.migrate(\.reactionActions, old.actions(Keys.reactionActions))
        settings.migrate(\.mediaActions, old.actions(Keys.mediaActions))
        settings.migrate(\.hidesEmptyComposeBar, old.bool(Keys.hidesEmptyComposeBar))
        settings.migrate(\.keepsComposeBarOpen, old.bool(Keys.keepsComposeBarOpen))
        settings.migrate(\.imageUploadSize, old.raw(Keys.imageUploadSize))
        settings.migrate(\.videoUploadSize, old.raw(Keys.videoUploadSize))
        settings.migrate(\.mediaDynamicRange, old.raw(Keys.mediaDynamicRange))
        settings.migrate(\.viewerMediaDynamicRange, old.raw(Keys.viewerMediaDynamicRange))
        for item in AppearanceCatalog.values + NotificationAppearanceCatalog.values {
            if let value = old.double(Keys.appearance(item.id)), item.range.contains(value), value != settings.value(of: item) {
                settings.setValue(value, for: item)
            }
        }
    }

    /// 前の版の値を、前の版と同じ型で読む。持っていないか読めない値はnil。
    private struct Reader {
        let defaults: UserDefaults

        func bool(_ key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
        func string(_ key: String) -> String? { defaults.string(forKey: key) }
        func double(_ key: String) -> Double? { defaults.object(forKey: key) as? Double }
        func data(_ key: String) -> Data? { defaults.data(forKey: key) }

        func raw<Value: RawRepresentable>(_ key: String) -> Value? where Value.RawValue == String {
            string(key).flatMap(Value.init(rawValue:))
        }

        func layout<Item: MenuItemKind>(_ key: String) -> MenuLayout<Item>? {
            defaults.stringArray(forKey: key).map(MenuLayout.init(tokens:))
        }

        func actions<Item: ObjectActionItem>(_ key: String) -> ObjectActions<Item>? {
            defaults.stringArray(forKey: key).map { ObjectActions(tokens: $0, default: .standard) }
        }
    }

    /// 前の版のキー。今の版も同じキーで端末に持つ値（訳す言語、翻訳モード、自動翻訳しないユーザー、プロフィールの絞り込み、肌の色、タブのメニューの「カスタマイズ」）は、移さず、消さない。
    private enum Keys {
        static let usesOriginalThumbnailsOnExpensiveNetwork = "settings.usesOriginalThumbnailsOnExpensiveNetwork"
        static let ignoresUselessAltText = "settings.ignoresUselessAltText"
        static let showsStatusBarTicker = "settings.showsStatusBarTicker"
        static let expandsXPosts = "settings.expandsXPosts"
        static let usesDynamicProfileAccent = "settings.usesDynamicProfileAccent"
        static let profileNoteLength = "settings.profileNoteLength"
        static let separatesProfilePinned = "settings.separatesProfilePinned"
        static let showsProfileFeaturedTags = "settings.showsProfileFeaturedTags"
        static let showsProfileEndorsements = "settings.showsProfileEndorsements"
        static let isAutoTranslationEnabled = "settings.isAutoTranslationEnabled"
        static let autoTranslationTarget = "settings.autoTranslationTarget"
        static let appearanceChoices = "settings.appearanceChoices"
        static let insertionMotion = "settings.insertionMotion"
        static let accentColor = "settings.accentColor"
        static let linkBrowser = "settings.linkBrowser"
        static let inAppBrowserSpaceAbove = "settings.inAppBrowserSpaceAbove"
        static let opensInAppBrowserFullScreen = "settings.opensInAppBrowserFullScreen"
        static let reblogVisibility = "settings.reblogVisibility"
        static let statusMenuLayout = "settings.statusMenuLayout"
        static let userMenuLayout = "settings.userMenuLayout"
        static let linkMenuLayout = "settings.linkMenuLayout"
        static let externalPostMenuLayout = "settings.externalPostMenuLayout"
        static let profileTextMenuLayout = "settings.profileTextMenuLayout"
        static let customEmojiMenuLayout = "settings.customEmojiMenuLayout"
        static let hashtagMenuLayout = "settings.hashtagMenuLayout"
        static let reactionMenuLayout = "settings.reactionMenuLayout"
        static let mediaMenuLayout = "settings.mediaMenuLayout"
        static let composeToolLayout = "settings.composeToolLayout"
        static let postActionBarLayout = "settings.postActionBarLayout"
        static let postLeadingSwipeLayout = "settings.postLeadingSwipeLayout"
        static let postTrailingSwipeLayout = "settings.postTrailingSwipeLayout"
        static let showsActionBarItemsInMenu = "settings.showsActionBarItemsInMenu"
        static let showsActionBarLongPressItemsInMenu = "settings.showsActionBarLongPressItemsInMenu"
        static let statusActions = "settings.objectActions.status"
        static let quotedStatusActions = "settings.objectActions.quotedStatus"
        static let notificationActions = "settings.objectActions.notification"
        static let userActions = "settings.objectActions.user"
        static let linkActions = "settings.objectActions.link"
        static let externalPostActions = "settings.objectActions.externalPost"
        static let hashtagActions = "settings.objectActions.hashtag"
        static let reactionActions = "settings.objectActions.reaction"
        static let mediaActions = "settings.objectActions.media"
        static let hidesEmptyComposeBar = "settings.hidesEmptyComposeBar"
        static let keepsComposeBarOpen = "settings.keepsComposeBarOpen"
        static let imageUploadSize = "settings.imageUploadSize"
        static let videoUploadSize = "settings.videoUploadSize"
        static let mediaDynamicRange = "settings.mediaDynamicRange"
        static let viewerMediaDynamicRange = "settings.viewerMediaDynamicRange"

        static func appearance(_ id: String) -> String {
            "settings.appearance.\(id)"
        }

        static let all: [String] = [
            usesOriginalThumbnailsOnExpensiveNetwork, ignoresUselessAltText, showsStatusBarTicker, expandsXPosts, usesDynamicProfileAccent,
            profileNoteLength, separatesProfilePinned, showsProfileFeaturedTags, showsProfileEndorsements, isAutoTranslationEnabled,
            autoTranslationTarget, appearanceChoices, insertionMotion, accentColor, linkBrowser, inAppBrowserSpaceAbove,
            opensInAppBrowserFullScreen, reblogVisibility, statusMenuLayout, userMenuLayout, linkMenuLayout, externalPostMenuLayout,
            profileTextMenuLayout, customEmojiMenuLayout, hashtagMenuLayout, reactionMenuLayout, mediaMenuLayout, composeToolLayout,
            postActionBarLayout, postLeadingSwipeLayout, postTrailingSwipeLayout, showsActionBarItemsInMenu,
            showsActionBarLongPressItemsInMenu, statusActions, quotedStatusActions, notificationActions, userActions, linkActions,
            externalPostActions, hashtagActions, reactionActions, mediaActions, hidesEmptyComposeBar, keepsComposeBarOpen,
            imageUploadSize, videoUploadSize, mediaDynamicRange, viewerMediaDynamicRange,
        ] + (AppearanceCatalog.values + NotificationAppearanceCatalog.values).map { appearance($0.id) }
    }
}

extension AppSettings {
    /// 前の版の値を、標準と違うときだけ書く。標準と同じ値まで書くと、変えていない項目まで「変えた項目」になるため。
    fileprivate func migrate<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ value: Value?) {
        guard let value, self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }
}
