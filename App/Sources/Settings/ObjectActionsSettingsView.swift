import SciaCore
import SwiftUI

/// 1つの対象のタップと長押しの操作を選ぶ画面。決まりはdocs/object-actions.mdの「設定画面」にある。
/// 選択は、先頭に「メニューを開く」、続けてその対象のメニューの項目を、既定の並びの順で、メニューと同じ名前とアイコンで並べる。
/// 項目が多いため、選ぶときは別の画面の一覧で選ぶ。
struct ObjectActionsSettingsView<Item: MenuItemKind & MenuItemPresentable>: View {
    let title: String
    @Binding var actions: ObjectActions<Item>

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
        }
        .navigationTitle(title)
    }

    private func picker(_ label: String, selection: Binding<ObjectAction<Item>>) -> some View {
        Picker(label, selection: selection) {
            Label("メニューを開く", systemImage: "contextualmenu.and.cursorarrow").tag(ObjectAction<Item>.menu)
            ForEach(items, id: \.self) { item in
                Label(item.title, systemImage: item.symbolName).tag(ObjectAction<Item>.item(item))
            }
        }
        .pickerStyle(.navigationLink)
    }

    /// メニューの既定の並びの順。メニューで隠しているかによらず、すべて並べる。
    private var items: [Item] {
        Item.defaultLayout.elements.compactMap { element in
            guard case .item(let item, _) = element else { return nil }
            return item
        }
    }
}

/// 設定の一覧に並べる、対象の行。今のタップと長押しの操作の名前を出す。
struct ObjectActionsRow<Item: ObjectActionItem & MenuItemPresentable>: View {
    let entity: ObjectEntity<Item>
    let settings: AppSettings

    private var actions: Binding<ObjectActions<Item>> {
        Binding(get: { settings[keyPath: entity.actions] }, set: { settings[keyPath: entity.actions] = $0 })
    }

    var body: some View {
        NavigationLink {
            ObjectActionsSettingsView(title: entity.title, actions: actions)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.title)
                Text("タップ: \(name(of: actions.wrappedValue.tap))、長押し: \(name(of: actions.wrappedValue.longPress))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func name(of action: ObjectAction<Item>) -> String {
        switch action {
        case .menu: "メニューを開く"
        case .item(let item): item.title
        }
    }
}
