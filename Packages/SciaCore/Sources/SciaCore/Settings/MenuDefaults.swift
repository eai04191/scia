import Foundation

/// 既定の並びを、アプリに入れたSettings/Resources/menu-defaults.jsonから読むメニュー。
/// JSONは、メニューごとのキーに、保存する形（`MenuLayout.tokens`）の並びを書く。Tools/MenuEditorのエディターで並べ替えて作れる。
public protocol BundledMenuDefaults: MenuItemKind {
    /// menu-defaults.jsonの中の、このメニューのキー。
    static var defaultsKey: String { get }
}

enum MenuDefaultsFile {
    /// menu-defaults.jsonの中身。アプリに入れたデータなので、読めないのは作りの誤りで、起動を止める。中身はテストで確かめる。
    static let tokens: [String: [String]] = {
        guard let url = Bundle.module.url(forResource: "menu-defaults", withExtension: "json") else {
            preconditionFailure("menu-defaults.jsonがパッケージに入っていない")
        }
        do {
            return try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("menu-defaults.jsonを読めない: \(error)")
        }
    }()
}

extension MenuLayout where Item: BundledMenuDefaults {
    /// menu-defaults.jsonの並び。足りない項目は差し込まない（差し込む位置を、この並びで決めるため）。
    /// キーがない、知らない書き方があるときは、既定のメニューが黙って欠けないよう起動を止める。
    public static func bundledDefault() -> MenuLayout<Item> {
        guard let tokens = MenuDefaultsFile.tokens[Item.defaultsKey] else {
            preconditionFailure("menu-defaults.jsonに\(Item.defaultsKey)がない")
        }
        return MenuLayout(defaultElements: tokens.map { token in
            guard let element = element(from: token) else {
                preconditionFailure("menu-defaults.jsonの\(Item.defaultsKey)に読めない項目がある: \(token)")
            }
            return element
        })
    }
}
