import SciaCore
import SwiftUI

/// 1つの対象の操作の画面。タップと長押しの操作を選び、その対象のメニューの並びの画面を開く。決まりはdocs/object-actions.mdの「設定画面」にある。
/// 選択は、先頭の欄に既定の「メニューを開く」とタップの既定の項目を、次の欄に残りのメニューの項目を、既定の並びの順で、メニューと同じ名前とアイコンで並べる。
/// 項目が多いため、選ぶときは別のリストで選ぶ。
struct ObjectActionsSettingsView<Item: MenuItemKind & MenuItemPresentable>: View {
    let title: String
    @Binding var actions: ObjectActions<Item>
    /// この対象のメニューの並びの画面。通知は投稿のメニューを出し、自分のメニューを持たないのでnil。
    let menu: SettingsPage?
    /// タップの既定の項目。長いリストに埋もれないよう、「メニューを開く」と並べて先頭の欄に出す。
    let primary: Item
    /// アクションバーのボタンの並びの画面。アクションバーを出せる対象（投稿）でだけ渡し、渡すと「アクションバーを開く」も選べる。
    var actionBar: SettingsPage?

    var body: some View {
        Form {
            Section {
                picker("タップ", selection: $actions.tap)
                picker("長押し", selection: $actions.longPress)
            } footer: {
                if !actions.opensMenu {
                    Text("タップでも長押しでもメニューを開かないため、\(title)のメニューにしかない操作は使えません。")
                }
            }
            if menu != nil || actionBar != nil {
                Section {
                    if let menu {
                        NavigationLink("メニュー", value: menu)
                    }
                    if let actionBar {
                        NavigationLink("アクションバー", value: actionBar)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 行の右端の今の値は、iPhoneの設定アプリと同じく、アイコンを付けない灰色の名前だけにする。アイコンは選ぶリストにだけ出す。
    private func picker(_ label: String, selection: Binding<ObjectAction<Item>>) -> some View {
        Picker(selection: selection) {
            Section {
                Label("メニューを開く", systemImage: "contextualmenu.and.cursorarrow").tag(ObjectAction<Item>.menu)
                option(primary)
                if actionBar != nil {
                    Label(ObjectAction<Item>.openActionBarTitle, systemImage: "rectangle.bottomhalf.inset.filled").tag(ObjectAction<Item>.actionBar)
                }
            }
            Section {
                ForEach(items.filter { $0 != primary }, id: \.self) { item in
                    option(item)
                }
            }
        } label: {
            Text(label)
        } currentValueLabel: {
            Text(name(of: selection.wrappedValue))
                .foregroundStyle(.secondary)
        }
        .pickerStyle(.navigationLink)
    }

    private func option(_ item: Item) -> some View {
        Label(item.title, systemImage: item.symbolName).tag(ObjectAction<Item>.item(item))
    }

    private func name(of action: ObjectAction<Item>) -> String {
        switch action {
        case .menu: "メニューを開く"
        case .item(let item): item.title
        case .actionBar: ObjectAction<Item>.openActionBarTitle
        }
    }

    /// メニューの既定の並びの順。メニューで隠しているかによらず、すべて並べる。
    private var items: [Item] {
        Item.defaultLayout.elements.compactMap { element in
            guard case .item(let item, _) = element else { return nil }
            return item
        }
    }
}

@MainActor
extension ObjectEntity {
    func actions(in settings: AppSettings) -> Binding<ObjectActions<Item>> {
        let actions = actions
        return Binding(get: { settings[keyPath: actions] }, set: { settings[keyPath: actions] = $0 })
    }
}

extension ObjectActionsSettingsView where Item: ObjectActionItem {
    init(entity: ObjectEntity<Item>, settings: AppSettings, menu: SettingsPage?, actionBar: SettingsPage? = nil) {
        self.init(title: entity.title, actions: entity.actions(in: settings), menu: menu, primary: Item.primaryItem, actionBar: actionBar)
    }
}
