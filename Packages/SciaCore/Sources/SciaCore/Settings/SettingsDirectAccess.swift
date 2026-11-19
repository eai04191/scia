import Foundation

/// 設定の値を、画面をたどらずにキーで読み書きする。デバッグ版の`scia-debug://settings`が使う（docs/debug-urls.md）。
/// 並べるキーは、設定の画面ごとのプリセットのキー（`AppSettings.keys(of:)`）と、タブの画面のプリセットに含めない値。
public struct SettingsDirectEntry: Hashable, Sendable {
    public let key: String
    /// 設定の画面での場所と名前（「メディア > 高画質のサムネイル」）。
    public let place: String
    /// 今の値。持っていなければ（アプリの既定値を使っていれば）nil。
    public let value: PresetValue?
}

public enum SettingsDirectAccessError: Error, Equatable, Sendable {
    case unknownKey(String)
    /// JSONの真偽値、数、文字列、文字列の配列、nullのどれでもない。
    case unreadableValue(String)
    /// アプリがその値を読めない（種類が違う、知らない選択肢、範囲の外など）。読む側が既定値に戻してしまい、書いたことにならないため。
    case unreadable(key: String, value: PresetValue)
    /// タブの並びの項目に、知らない名前がある。
    case unknownTabItems([String])
}

extension PresetValue {
    /// JSONの値から作る。nullは`.null`。
    public init(json: String) throws(SettingsDirectAccessError) {
        let decoder = JSONDecoder()
        let data = Data(json.utf8)
        if let value = try? decoder.decode(Bool.self, from: data) {
            self = .bool(value)
        } else if let value = try? decoder.decode(Double.self, from: data) {
            self = .number(value)
        } else if let value = try? decoder.decode(String.self, from: data) {
            self = .text(value)
        } else if let value = try? decoder.decode([String].self, from: data) {
            self = .list(value)
        } else if (try? decoder.decode(JSONNull.self, from: data)) != nil {
            self = .null
        } else {
            throw .unreadableValue(json)
        }
    }

    /// JSONに書いた形。
    public var json: String {
        let object: Any = switch self {
        case .bool(let value): value
        case .number(let value): value
        case .text(let value): value
        case .list(let value): value
        case .null: NSNull()
        }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

private struct JSONNull: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard container.decodeNil() else {
            throw DecodingError.typeMismatch(JSONNull.self, .init(codingPath: [], debugDescription: "not null"))
        }
    }
}

extension AppSettings {
    /// タブの並び。`account`のアカウントのもの。
    public static let tabLayoutDirectKey = "tabLayout"
    /// 切り替えタブのメニューに「カスタマイズ」を出すか。アプリ全体で1つ。
    public static let showsTabMenuCustomizeDirectKey = "showsTabMenuCustomize"
    /// 自動翻訳で訳す投稿の言語、翻訳モード、訳さない人のハンドル。プリセットに含めない値。
    public static let autoTranslationLanguagesDirectKey = "autoTranslationLanguages"
    public static let autoTranslationStrategyDirectKey = "autoTranslationStrategy"
    public static let autoTranslationExcludedHandlesDirectKey = "autoTranslationExcludedHandles"

    /// 読んでいるプリセットの値と、`account`のタブの設定を、設定の画面の順に並べる。
    public func directEntries(account: String) -> [SettingsDirectEntry] {
        let presetEntries = Self.directPlaces.map { key, place in
            SettingsDirectEntry(key: key, place: place, value: value(key))
        }
        let tabs = Self.pagePath(.tabs).joined(separator: " > ")
        let translation = Self.pagePath(.autoTranslation).joined(separator: " > ")
        return presetEntries + [
            SettingsDirectEntry(key: Self.tabLayoutDirectKey, place: tabs, value: .list(tabLayout(for: account).tokens)),
            SettingsDirectEntry(key: Self.showsTabMenuCustomizeDirectKey, place: tabs, value: .bool(showsTabMenuCustomize)),
            SettingsDirectEntry(key: Self.autoTranslationLanguagesDirectKey, place: translation, value: .list(autoTranslationLanguages)),
            SettingsDirectEntry(key: Self.autoTranslationStrategyDirectKey, place: translation, value: .text(autoTranslationStrategy.rawValue)),
            SettingsDirectEntry(key: Self.autoTranslationExcludedHandlesDirectKey, place: translation, value: .list(autoTranslationExcludedHandles)),
        ]
    }

    /// 画面で変えたときと同じく、読んでいるプリセットへ書く。タブの設定は`account`のものを書く。
    public func setDirectly(_ value: PresetValue, forKey key: String, account: String) throws(SettingsDirectAccessError) {
        switch key {
        case Self.tabLayoutDirectKey:
            guard case .list(let tokens) = value else { throw .unreadable(key: key, value: value) }
            let layout = MenuLayout<TabItem>(tokens: tokens)
            let unknown = tokens.filter { !layout.tokens.contains($0) }
            guard unknown.isEmpty else { throw .unknownTabItems(unknown) }
            setTabLayout(layout, for: account)
        case Self.showsTabMenuCustomizeDirectKey:
            guard case .bool(let isOn) = value else { throw .unreadable(key: key, value: value) }
            showsTabMenuCustomize = isOn
        case Self.autoTranslationLanguagesDirectKey:
            guard case .list(let languages) = value else { throw .unreadable(key: key, value: value) }
            autoTranslationLanguages = languages
        case Self.autoTranslationStrategyDirectKey:
            guard case .text(let raw) = value, let strategy = TranslationStrategy(rawValue: raw) else { throw .unreadable(key: key, value: value) }
            autoTranslationStrategy = strategy
        case Self.autoTranslationExcludedHandlesDirectKey:
            guard case .list(let handles) = value else { throw .unreadable(key: key, value: value) }
            autoTranslationExcludedHandles = handles
        default:
            guard Self.directPlaces.contains(where: { $0.key == key }) else { throw .unknownKey(key) }
            guard canReadDirectly(value, forKey: key) else { throw .unreadable(key: key, value: value) }
            write(value, key)
        }
    }

    /// 「投稿の見た目」の選んで決める項目は、項目ごとに読まず、まとめて`AppearanceChoices`に読むので、そこを通して戻るかで確かめる。
    /// ほかの値は、プリセットの比較の画面と同じ読み方で、そのキーを読む設定の値を読ませる。
    private func canReadDirectly(_ value: PresetValue, forKey key: String) -> Bool {
        if let field = AppearanceStorage.fieldNames.first(where: { AppearanceStorage.key($0) == key }) {
            return AppearanceStorage.fields(of: AppearanceStorage.choices(from: [field: value]))[field] == value
        }
        let reads = Self.comparisonEntries.filter { $0.keys.contains(key) }.map(\.read)
        guard !reads.isEmpty else { return false }
        return canRead(value, forKey: key) {
            for read in reads { _ = read(self) }
        }
    }

    private static let comparisonEntries = PresetComparison.catalog(languageName: { $0 }, deviceLanguageName: "").flatMap(\.entries)

    /// プリセットのキーと、設定の画面での場所。キーを持つ画面のうち、持つキーがいちばん少ない画面を場所にする。分類の画面は中の画面のキーも持つため。
    private static let directPlaces: [(key: String, place: String)] = {
        let pages = SettingsPage.allCases.map { (page: $0, keys: keys(of: $0)) }
        var seen: Set<String> = []
        var places: [(key: String, place: String)] = []
        for (_, keys) in pages {
            for key in keys where seen.insert(key).inserted {
                let page = pages.filter { $0.keys.contains(key) }.min { $0.keys.count < $1.keys.count }?.page
                let path = (page.map { pagePath($0) } ?? []) + [itemTitles[key]].compactMap(\.self)
                places.append((key, path.joined(separator: " > ")))
            }
        }
        return places
    }()

    /// トップの画面から`page`までの画面の題。同じ題の画面（表示の「投稿」と操作の「投稿」）を見分けるため。
    private static func pagePath(_ page: SettingsPage) -> [String] {
        var path = [page.title()]
        var current = page
        while let parent = parentPages[current] {
            path.insert(parent.title(), at: 0)
            current = parent
        }
        return path
    }

    /// 画面と、その画面へ入る行を並べた画面。
    private static let parentPages: [SettingsPage: SettingsPage] = {
        var parents: [SettingsPage: SettingsPage] = [:]
        for page in SettingsPage.allCases {
            for case .page(let child) in (page.sections ?? []).flatMap(\.rows) { parents[child] = page }
            if let screen = ObjectActionsScreen(page) {
                for child in [screen.menu, screen.actionBar].compactMap(\.self) + screen.swipes.map(\.page) { parents[child] = page }
            }
        }
        return parents
    }()

    /// 画面の中で、キーごとに付いている行の名前。見た目の項目には、分類の名前を前に付ける。
    private static let itemTitles: [String: String] = {
        var titles: [String: String] = [:]
        for item in SettingsItem.allCases {
            for key in keys(of: item) { titles[key] = item.title }
        }
        for choice in AppearanceChoice.allCases {
            titles[AppearanceStorage.key(choice.field)] = choice.title
        }
        for group in AppearanceCatalog.groups {
            for value in group.values { titles[appearanceKey(value)] = "\(group.title) > \(value.title)" }
            for choice in AppearanceChoice.choices(inGroup: group.id) {
                titles[AppearanceStorage.key(choice.field)] = "\(group.title) > \(choice.title)"
            }
        }
        for group in NotificationAppearanceCatalog.groups {
            for value in group.values { titles[appearanceKey(value)] = "\(group.title) > \(value.title)" }
        }
        for page in SettingsPage.allCases {
            guard let actionsKey = actionsKey(of: page) else { continue }
            titles[key(of: .tap, in: actionsKey)] = "tap"
            titles[key(of: .longPress, in: actionsKey)] = "longPress"
        }
        return titles
    }()
}
