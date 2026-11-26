import Foundation

/// 2つのプリセットで読む値の違う項目を、設定の画面の階層ごとのセクションに分けたもの。決まりはdocs/preset.mdの「プリセットを比較」にある。
@MainActor
public struct PresetComparison {
    public struct Section: Identifiable {
        /// 比べる項目の並びでの順番。見出しは、対象の操作の画面とセクションの見出しで同じになることがある（「操作>リンク」）ので、見出しとは別に持つ。
        public let id: Int
        /// 設定の画面の階層の名前を、上から順に並べたもの。画面ではシェブロンでつなぐ。
        public let path: [String]
        public let rows: [Row]

        /// 読み上げる見出し。
        public var accessibilityTitle: String {
            SettingsTexts.Presets.pathAccessibilityLabel(path)
        }
    }

    public struct Row: Identifiable {
        public let title: String
        /// 並びを開いた画面の題。行の名前は親の画面で何の並びか分かるように短く書くので、開いた画面では並びの画面の題を使う。
        public let detailTitle: String
        public let base: Reading
        public let compared: Reading
        /// この項目の値を持つ、プリセットのキー。
        let keys: [String]
        public var id: String { keys.joined(separator: " ") }
    }

    /// 1つのプリセットで読んだ値。
    public enum Reading: Equatable, Sendable {
        case text(TextLists.ItemList)
        /// メニューなどの並び。
        case layout([LayoutLine])
    }

    /// 並びの1つの要素。並びのとおりに上から並べる。
    public enum LayoutLine: Hashable, Sendable {
        case item(title: String, symbolName: String, isVisible: Bool)
        case separator
        /// 横並びの区切り線。`title`は横に並べる大きさの名前。
        case rowSeparator(title: String)
        /// これより下は「その他」などの、境目の後ろのセクション。
        case more(title: String)
    }

    /// 読む値が違う項目のあるセクション。
    public let sections: [Section]

    /// - Parameters:
    ///   - languageName: 言語のコードから、使う人に見せる言語の名前を返す。
    ///   - deviceLanguageName: 端末の言語の名前。自動翻訳の翻訳先を選んでいないときの値に使う。
    public init(base: AppSettings, compared: AppSettings, languageName: @escaping (String) -> String, deviceLanguageName: String) {
        let catalog = Self.catalog(languageName: languageName, deviceLanguageName: deviceLanguageName)
        sections = catalog.enumerated().compactMap { index, section in
            let rows = section.entries.compactMap { entry -> Row? in
                guard !entry.isSame(base, compared) else { return nil }
                let before = entry.read(base)
                let after = entry.read(compared)
                return Row(title: entry.title, detailTitle: entry.detailTitle ?? entry.title, base: before, compared: after, keys: entry.keys)
            }
            return rows.isEmpty ? nil : Section(id: index, path: section.path, rows: rows)
        }
    }

    /// 比べる項目。どの項目も、プリセットに含める値のキーを持つ。
    struct Entry {
        let title: String
        var detailTitle: String?
        let keys: [String]
        let read: @MainActor (AppSettings) -> Reading
        /// 2つの設定で、この項目の値が同じか。読んだ値の文字は丸めや省略で違いを落とすことがあるので、文字ではなく値で比べる項目は、ここで比べる。
        var same: (@MainActor (AppSettings, AppSettings) -> Bool)?

        @MainActor
        func isSame(_ base: AppSettings, _ compared: AppSettings) -> Bool {
            same.map { $0(base, compared) } ?? (read(base) == read(compared))
        }
    }

    struct EntrySection {
        let path: [String]
        var entries: [Entry]
    }

    /// 比べる項目を、設定の画面の「表示」「操作」「作成」から、画面の並びのとおりにたどって集める。
    static func catalog(languageName: @escaping (String) -> String, deviceLanguageName: String) -> [EntrySection] {
        var builder = CatalogBuilder(languageName: languageName, deviceLanguageName: deviceLanguageName)
        for page in [SettingsPage.display, .interaction, .compose] {
            builder.walk(page, path: [])
        }
        return builder.sections
    }
}

extension PresetComparison {
    static func on(_ isOn: Bool) -> Reading {
        .text(TextLists.ItemList(single: isOn ? SettingsTexts.Presets.on : SettingsTexts.Presets.off))
    }

    static func text(_ text: String) -> Reading {
        .text(TextLists.ItemList(single: text))
    }

    static func valueText(_ value: Double, _ item: AppearanceValue) -> String {
        let number = numberText(value, step: item.step)
        switch item.unit {
        case .point: return SettingsTexts.Presets.points(number)
        case .ratio: return number
        case .bodyTextOffset, .textOffset, .count: return item.note(for: value) ?? number
        case .lines: return item.note(for: value) ?? SettingsTexts.Presets.lines(number)
        }
    }

    /// 刻みの桁まで書いた数。刻みの倍数から外れて打った値も、刻みの桁で書く。
    static func numberText(_ value: Double, step: Double) -> String {
        var digits = 0
        var scaled = step
        while digits < 4, (scaled - scaled.rounded()).magnitude > 1e-9 {
            digits += 1
            scaled *= 10
        }
        return digits == 0 ? AppearanceValue.numberText(value) : String(format: "%.\(digits)f", value)
    }

    static func layoutLines<Item: MenuItemPresentable>(_ layout: MenuLayout<Item>) -> Reading {
        .layout(layout.elements.compactMap { element in
            switch element {
            case .item(let item, let isVisible): .item(title: item.title, symbolName: item.symbolName, isVisible: isVisible)
            case .separator: .separator
            case .rowSeparator(let size): .rowSeparator(title: size.title)
            case .more: Item.hasMoreSection ? .more(title: Item.moreSectionTitle) : nil
            }
        })
    }

    static func actionText<Item: MenuItemPresentable>(_ action: ObjectAction<Item>) -> Reading {
        switch action {
        case .menu: text(ObjectActionsScreen.openMenuTitle)
        case .item(let item): text(item.title)
        case .actionBar: text(ObjectAction<Item>.openActionBarTitle)
        }
    }
}

/// 設定の画面をたどって、比べる項目をセクションに分けて集める。
@MainActor
private struct CatalogBuilder {
    typealias Entry = PresetComparison.Entry
    typealias Reading = PresetComparison.Reading

    let languageName: (String) -> String
    let deviceLanguageName: String
    private(set) var sections: [PresetComparison.EntrySection] = []

    init(languageName: @escaping (String) -> String, deviceLanguageName: String) {
        self.languageName = languageName
        self.deviceLanguageName = deviceLanguageName
    }

    mutating func walk(_ page: SettingsPage, path: [String]) {
        let here = path + [page.title]
        if let entry = layoutEntry(page) {
            add([entry], to: path)
            return
        }
        switch page {
        case .appearance:
            add([choiceEntry(title: SettingsTexts.Appearance.revealsAllPartsInThread, field: AppearanceStorage.revealsAllPartsInThread) { $0.appearance.revealsAllPartsInThread }], to: here)
            for group in AppearanceCatalog.groups {
                add(AppearanceChoice.choices(inGroup: group.id).map(choiceEntry) + group.values.map(valueEntry), to: here + [group.title])
            }
        case .notificationAppearance:
            for group in NotificationAppearanceCatalog.groups {
                add(group.values.map(valueEntry), to: here + [group.title])
            }
        case .autoTranslation:
            add(AutoTranslationSetting.allCases.map(autoTranslationEntry), to: here)
        default:
            if let screen = ObjectActionsScreen(page) {
                walk(screen, path: here)
                return
            }
            for section in page.sections ?? [] {
                let sectionPath = here + (section.header.map { [$0] } ?? [])
                for row in section.rows {
                    switch row {
                    case .item(let item): add(itemEntry(item).map { [$0] } ?? [], to: sectionPath)
                    case .page(let child): walk(child, path: sectionPath)
                    }
                }
            }
        }
    }

    private mutating func walk(_ screen: ObjectActionsScreen, path: [String]) {
        guard let key = AppSettings.actionsKey(of: screen.page) else { preconditionFailure("\(screen.page)に操作のキーがない") }
        add([.tap, .longPress].map { actionEntry(screen.page, $0, key: key) }, to: path)
        for page in [screen.menu, screen.actionBar].compactMap(\.self) + screen.swipes.map(\.page) {
            walk(page, path: path)
        }
        add(screen.toggles.map { toggle in
            Entry(title: toggle.title, keys: [AppSettings.key(of: toggle)]) { settings in
                switch toggle {
                case .actionBarItemsInMenu: PresetComparison.on(settings.showsActionBarItemsInMenu)
                case .actionBarLongPressItemsInMenu: PresetComparison.on(settings.showsActionBarLongPressItemsInMenu)
                }
            }
        }, to: path)
    }

    /// 同じ階層のセクションが続いていれば、そこに足す。空の項目は足さない。
    private mutating func add(_ entries: [Entry], to path: [String]) {
        guard !entries.isEmpty else { return }
        if sections.last?.path == path {
            sections[sections.count - 1].entries += entries
        } else {
            sections.append(PresetComparison.EntrySection(path: path, entries: entries))
        }
    }

    private func valueEntry(_ item: AppearanceValue) -> Entry {
        Entry(title: item.title, keys: [AppSettings.appearanceKey(item)], read: { settings in
            PresetComparison.text(PresetComparison.valueText(settings.value(of: item), item))
        }, same: { $0.value(of: item) == $1.value(of: item) })
    }

    private func choiceEntry(_ choice: AppearanceChoice) -> Entry {
        Entry(title: choice.title, keys: [AppearanceStorage.key(choice.field)]) { settings in
            switch choice.control {
            case .toggle(let keyPath): PresetComparison.on(settings[keyPath: keyPath])
            case .options(let options): PresetComparison.text(options.titles[options.selectedIndex(settings)])
            }
        }
    }

    private func choiceEntry(title: String, field: String, isOn: @escaping @MainActor (AppSettings) -> Bool) -> Entry {
        Entry(title: title, keys: [AppearanceStorage.key(field)]) { PresetComparison.on(isOn($0)) }
    }

    private func autoTranslationEntry(_ setting: AutoTranslationSetting) -> Entry {
        let languageName = languageName
        let deviceLanguageName = deviceLanguageName
        let title = switch setting {
        case .enabled: SettingsTexts.AutoTranslation.toggle
        case .target: SettingsTexts.AutoTranslation.target
        }
        return Entry(title: title, keys: [AppSettings.key(of: setting)]) { settings in
            switch setting {
            case .enabled: PresetComparison.on(settings.isAutoTranslationEnabled)
            case .target: PresetComparison.text(settings.autoTranslationTarget.map(languageName) ?? SettingsTexts.AutoTranslation.deviceLanguage(name: deviceLanguageName))
            }
        }
    }

    private func itemEntry(_ item: SettingsItem) -> Entry? {
        let keys = AppSettings.keys(of: item)
        guard !keys.isEmpty else { return nil }
        return Entry(title: item.title, keys: keys) { settings in
            switch item {
            case .accentColor: PresetComparison.text(settings.accentColor.title)
            case .insertionMotion: PresetComparison.text(settings.insertionMotion.title)
            case .statusBarTicker: PresetComparison.on(settings.showsStatusBarTicker)
            case .linkBrowser: PresetComparison.text(settings.linkBrowser.title)
            // 全画面で開いても、つまみを下げたときは保存した高さを使うので、高さも出す。
            case .inAppBrowserHeight:
                settings.opensInAppBrowserFullScreen
                    ? PresetComparison.text(SettingsTexts.Presets.fullScreenInAppBrowser(height: settings.inAppBrowserHeight.title))
                    : PresetComparison.text(settings.inAppBrowserHeight.title)
            case .reblogVisibility: PresetComparison.text(settings.reblogVisibility.title)
            case .composeBarIdle: PresetComparison.text(settings.composeBarIdle.title)
            case .imageUploadSize: PresetComparison.text(settings.imageUploadSize.title)
            case .videoUploadSize: PresetComparison.text(settings.videoUploadSize.title)
            case .mediaDynamicRange: PresetComparison.text(settings.mediaDynamicRange.title)
            case .viewerMediaDynamicRange: PresetComparison.text(settings.viewerMediaDynamicRange.title)
            case .originalThumbnailsOnExpensiveNetwork: PresetComparison.on(settings.usesOriginalThumbnailsOnExpensiveNetwork)
            case .expandsXPosts: PresetComparison.on(settings.expandsXPosts)
            case .profileNoteLength: PresetComparison.text(settings.profileNoteLength.title)
            case .profilePinned: PresetComparison.on(settings.separatesProfilePinned)
            case .profileFeaturedTags: PresetComparison.on(settings.showsProfileFeaturedTags)
            case .profileEndorsements: PresetComparison.on(settings.showsProfileEndorsements)
            case .dynamicProfileAccent: PresetComparison.on(settings.usesDynamicProfileAccent)
            case .ignoresUselessAltText: PresetComparison.on(settings.ignoresUselessAltText)
            case .version, .build, .branch, .commit, .builtAt, .sourceCode, .privacyPolicy:
                preconditionFailure("\(item)はプリセットに値を持たない")
            }
        }
    }

    private func actionEntry(_ page: SettingsPage, _ trigger: ObjectTrigger, key: String) -> Entry {
        let title = switch trigger {
        case .tap: ObjectActionsScreen.tapTitle
        case .longPress: ObjectActionsScreen.longPressTitle
        }
        return Entry(title: title, keys: [AppSettings.key(of: trigger, in: key)]) { settings in
            switch page {
            case .statusActions: PresetComparison.actionText(settings.statusActions[trigger])
            case .quotedStatusActions: PresetComparison.actionText(settings.quotedStatusActions[trigger])
            case .notificationActions: PresetComparison.actionText(settings.notificationActions[trigger])
            case .userActions: PresetComparison.actionText(settings.userActions[trigger])
            case .linkActions: PresetComparison.actionText(settings.linkActions[trigger])
            case .externalPostActions: PresetComparison.actionText(settings.externalPostActions[trigger])
            case .hashtagActions: PresetComparison.actionText(settings.hashtagActions[trigger])
            case .reactionActions: PresetComparison.actionText(settings.reactionActions[trigger])
            case .mediaActions: PresetComparison.actionText(settings.mediaActions[trigger])
            default: preconditionFailure("\(page)は対象の操作の画面ではない")
            }
        }
    }

    /// 並びの画面なら、その並びの項目。行の名前は親の画面の行と同じにする。
    private func layoutEntry(_ page: SettingsPage) -> Entry? {
        let read: (@MainActor (AppSettings) -> Reading)? = switch page {
        case .statusMenu: { PresetComparison.layoutLines($0.statusMenuLayout) }
        case .statusActionBar: { PresetComparison.layoutLines($0.postActionBarLayout) }
        case .statusLeadingSwipe: { PresetComparison.layoutLines($0.postLeadingSwipeLayout) }
        case .statusTrailingSwipe: { PresetComparison.layoutLines($0.postTrailingSwipeLayout) }
        case .userMenu: { PresetComparison.layoutLines($0.userMenuLayout) }
        case .linkMenu: { PresetComparison.layoutLines($0.linkMenuLayout) }
        case .externalPostMenu: { PresetComparison.layoutLines($0.externalPostMenuLayout) }
        case .profileTextMenu: { PresetComparison.layoutLines($0.profileTextMenuLayout) }
        case .customEmojiMenu: { PresetComparison.layoutLines($0.customEmojiMenuLayout) }
        case .hashtagMenu: { PresetComparison.layoutLines($0.hashtagMenuLayout) }
        case .mediaMenu: { PresetComparison.layoutLines($0.mediaMenuLayout) }
        case .reactionMenu: { PresetComparison.layoutLines($0.reactionMenuLayout) }
        case .composeTools: { PresetComparison.layoutLines($0.composeToolLayout) }
        default: nil
        }
        return read.map { Entry(title: page.rowTitle, detailTitle: page.title, keys: AppSettings.keys(of: page), read: $0) }
    }
}
