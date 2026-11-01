import Testing
@testable import SciaCore

/// menu-defaults.jsonの並びが、読んだときに足したり捨てたりせずに済む形かを確かめる。
/// 読めない並びは起動を止め、足りない項目は保存した並びと同じ決まりで差し込まれて既定と食い違うため。
struct MenuDefaultsTests {
    private static let keys: [String] = [
        StatusMenuItem.defaultsKey,
        UserMenuItem.defaultsKey,
        LinkMenuItem.defaultsKey,
        ExternalPostMenuItem.defaultsKey,
        ProfileTextMenuItem.defaultsKey,
        HashtagMenuItem.defaultsKey,
        MediaMenuItem.defaultsKey,
    ]

    @Test("JSONにあるメニューは、BundledMenuDefaultsのメニューとちょうど同じ")
    func keysMatch() {
        #expect(Set(MenuDefaultsFile.tokens.keys) == Set(Self.keys))
        #expect(Set(Self.keys).count == Self.keys.count)
    }

    @Test("どのメニューの並びも、項目をすべて1つずつと「その他」を1つ持つ")
    func layoutsAreComplete() {
        check(StatusMenuItem.self)
        check(UserMenuItem.self)
        check(LinkMenuItem.self)
        check(ExternalPostMenuItem.self)
        check(ProfileTextMenuItem.self)
        check(HashtagMenuItem.self)
        check(MediaMenuItem.self)
    }

    private func check<Item: BundledMenuDefaults>(_: Item.Type) {
        let tokens = MenuDefaultsFile.tokens[Item.defaultsKey] ?? []
        let elements = tokens.compactMap(MenuLayout<Item>.element(from:))
        #expect(elements.count == tokens.count, "\(Item.defaultsKey)に読めない項目がある")
        let items = elements.compactMap { element -> Item? in
            if case .item(let item, _) = element { item } else { nil }
        }
        #expect(items.count == Item.allCases.count, "\(Item.defaultsKey)の項目の数")
        #expect(Set(items) == Set(Item.allCases), "\(Item.defaultsKey)に足りない項目がある")
        #expect(elements.filter { $0 == .more }.count == 1, "\(Item.defaultsKey)の「その他」の数")
        #expect(MenuLayout<Item>(tokens: tokens).tokens == tokens, "\(Item.defaultsKey)は読み直すと変わる")
    }
}
