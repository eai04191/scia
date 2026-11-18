/// 2つの設定で、読む値が違う項目。組み込みのプリセットを調整するときに、アプリの既定値との違いを並べる（部品カタログの「組み込みのプリセット」）。
public struct PresetDifference: Hashable, Sendable {
    /// 分類と項目の名前。
    public let title: String
    /// 比べるもとの設定の値。
    public let base: String
    /// 比べる設定の値。
    public let compared: String
    /// この項目の値を持つ、プリセットのキー。
    let keys: [String]
}

extension AppSettings {
    /// `base`と読む値が違う項目。「投稿の見た目」と「通知の見た目」の数値と選択肢、対象の操作のタップと長押しを、設定の画面の並びで比べる。
    /// 組み込みのプリセットが持つキーは、どれもここで比べる項目に入る（テストで確かめる）。
    public func differences(from base: AppSettings) -> [PresetDifference] {
        valueDifferences(from: base) + choiceDifferences(from: base) + actionDifferences(from: base)
    }

    private func valueDifferences(from base: AppSettings) -> [PresetDifference] {
        let groups = AppearanceCatalog.groups.map { (prefix: $0.title, group: $0) }
            + NotificationAppearanceCatalog.groups.map { (prefix: "\(SettingsPage.notificationAppearance.title)・\($0.title)", group: $0) }
        return groups.flatMap { prefix, group in
            group.values.compactMap { item -> PresetDifference? in
                let before = base.value(of: item)
                let after = value(of: item)
                guard before != after else { return nil }
                return PresetDifference(title: "\(prefix)・\(item.title)", base: Self.text(of: before, item), compared: Self.text(of: after, item), keys: [Self.appearanceKey(item)])
            }
        }
    }

    private static func text(of value: Double, _ item: AppearanceValue) -> String {
        let number = AppearanceValue.numberText(value)
        return item.note(for: value).map { "\(number)（\($0)）" } ?? number
    }

    private func choiceDifferences(from base: AppSettings) -> [PresetDifference] {
        AppearanceCatalog.groups.flatMap { group in
            AppearanceChoice.choices(inGroup: group.id).compactMap { choice -> PresetDifference? in
                let before = Self.text(of: choice, in: base)
                let after = Self.text(of: choice, in: self)
                guard before != after else { return nil }
                return PresetDifference(title: "\(group.title)・\(choice.title)", base: before, compared: after, keys: [AppearanceStorage.key(choice.field)])
            }
        }
    }

    private static func text(of choice: AppearanceChoice, in settings: AppSettings) -> String {
        switch choice.control {
        case .toggle(let keyPath): settings[keyPath: keyPath] ? "オン" : "オフ"
        case .options(let options): options.titles[options.selectedIndex(settings)]
        }
    }

    private func actionDifferences(from base: AppSettings) -> [PresetDifference] {
        [
            Self.actionDifferences(.statusActions, \.statusActions, base: base, compared: self),
            Self.actionDifferences(.quotedStatusActions, \.quotedStatusActions, base: base, compared: self),
            Self.actionDifferences(.notificationActions, \.notificationActions, base: base, compared: self),
            Self.actionDifferences(.userActions, \.userActions, base: base, compared: self),
            Self.actionDifferences(.linkActions, \.linkActions, base: base, compared: self),
            Self.actionDifferences(.externalPostActions, \.externalPostActions, base: base, compared: self),
            Self.actionDifferences(.hashtagActions, \.hashtagActions, base: base, compared: self),
            Self.actionDifferences(.reactionActions, \.reactionActions, base: base, compared: self),
            Self.actionDifferences(.mediaActions, \.mediaActions, base: base, compared: self),
        ].flatMap(\.self)
    }

    private static func actionDifferences<Item: MenuItemPresentable>(_ page: SettingsPage, _ keyPath: KeyPath<AppSettings, ObjectActions<Item>>, base: AppSettings, compared: AppSettings) -> [PresetDifference] {
        guard let actionsKey = actionsKey(of: page) else { preconditionFailure("\(page)は対象の操作の画面ではない") }
        let triggers: [(ObjectTrigger, String)] = [(.tap, ObjectActionsScreen.tapTitle), (.longPress, ObjectActionsScreen.longPressTitle)]
        return triggers.compactMap { trigger, triggerTitle in
            let before = base[keyPath: keyPath][trigger]
            let after = compared[keyPath: keyPath][trigger]
            guard before != after else { return nil }
            return PresetDifference(title: "\(SettingsPage.interaction.title)・\(page.title)・\(triggerTitle)", base: text(of: before), compared: text(of: after), keys: [key(of: trigger, in: actionsKey)])
        }
    }

    private static func text<Item: MenuItemPresentable>(of action: ObjectAction<Item>) -> String {
        switch action {
        case .menu: ObjectActionsScreen.openMenuTitle
        case .item(let item): item.title
        case .actionBar: ObjectAction<Item>.openActionBarTitle
        }
    }
}
