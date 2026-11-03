import Foundation
import SciaCore

// 使い方: menu-editor <editor.htmlのパス> <書き出すパス>
// editor.htmlの`__MENU_CATALOG__`を、メニューごとの項目と今の既定の並びのJSONに置き換える。

struct Catalog: Encodable {
    let menus: [Menu]
}

struct Menu: Encodable {
    let key: String
    let title: String
    let moreTitle: String
    let supportsSeparators: Bool
    let supportsRowSeparators: Bool
    let items: [Item]
    let defaults: [String]
}

struct Item: Encodable {
    let id: String
    let title: String
    let symbol: String
}

func menu<Kind: BundledMenuDefaults & MenuItemPresentable>(_: Kind.Type, title: String) -> Menu {
    Menu(
        key: Kind.defaultsKey,
        title: title,
        moreTitle: Kind.moreSectionTitle,
        supportsSeparators: Kind.supportsSeparators,
        supportsRowSeparators: Kind.supportsRowSeparators,
        items: Kind.allCases.map { Item(id: $0.rawValue, title: $0.title, symbol: $0.symbolName) },
        defaults: Kind.defaultLayout.tokens
    )
}

// 並びは、menu-defaults.jsonに書き出すキーの順にもなる。名前は設定の画面に揃える。
let catalog = Catalog(menus: [
    menu(StatusMenuItem.self, title: "投稿のメニュー"),
    menu(UserMenuItem.self, title: "ユーザーのメニュー"),
    menu(LinkMenuItem.self, title: "リンクのメニュー"),
    menu(ExternalPostMenuItem.self, title: "ほかのサービスの投稿のメニュー"),
    menu(ProfileTextMenuItem.self, title: "プロフィールの文章のメニュー"),
    menu(HashtagMenuItem.self, title: "ハッシュタグのメニュー"),
    menu(MediaMenuItem.self, title: "メディアのメニュー"),
])

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("使い方: menu-editor <editor.html> <出力先>\n".utf8))
    exit(64)
}
let template = try String(contentsOfFile: arguments[1], encoding: .utf8)
guard template.contains("__MENU_CATALOG__") else {
    FileHandle.standardError.write(Data("\(arguments[1])に__MENU_CATALOG__がない\n".utf8))
    exit(65)
}
// JSONEncoderは`/`を`\/`にするので、`</script>`で埋め込んだscriptが閉じない。
let json = try String(decoding: JSONEncoder().encode(catalog), as: UTF8.self)
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try template.replacingOccurrences(of: "__MENU_CATALOG__", with: json).write(to: output, atomically: true, encoding: .utf8)
print(output.path)
