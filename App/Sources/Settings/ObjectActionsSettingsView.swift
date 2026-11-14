import SciaCore
import SwiftUI

/// 1つの対象の操作の画面。タップと長押しの操作を選び、その対象のメニューの並びの画面を開く。決まりはdocs/object-actions.mdの「設定画面」にある。
/// 選択は、先頭の欄に既定の「メニューを開く」とタップの既定の項目を、次の欄に残りのメニューの項目を、既定の並びの順で、メニューと同じ名前とアイコンで並べる。
/// 項目が多いため、選ぶときは別のリストで選ぶ。
struct ObjectActionsSettingsView<Item: MenuItemKind & MenuItemPresentable>: View {
    /// 何を並べるか。`ObjectActionsScreen`にある。
    let screen: ObjectActionsScreen
    @Bindable var settings: AppSettings
    @Binding var actions: ObjectActions<Item>
    /// タップの既定の項目。長いリストに埋もれないよう、「メニューを開く」と並べて先頭の欄に出す。
    let primary: Item

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Form {
            Section {
                picker(ObjectActionsScreen.tapTitle, selection: $actions.tap)
                picker(ObjectActionsScreen.longPressTitle, selection: $actions.longPress)
            } footer: {
                if !actions.opensMenu {
                    Text(screen.noMenuFooter())
                }
            }
            if screen.menu != nil || screen.actionBar != nil {
                Section {
                    if let menu = screen.menu {
                        NavigationLink(menu.rowTitle, value: menu)
                    }
                    if let actionBar = screen.actionBar {
                        NavigationLink(actionBar.rowTitle, value: actionBar)
                    }
                }
            }
            if !screen.swipes.isEmpty {
                Section {
                    ForEach(screen.swipes, id: \.self) { side in
                        swipeRow(side)
                    }
                }
            }
            if !screen.toggles.isEmpty {
                Section {
                    ForEach(screen.toggles, id: \.self) { toggle in
                        Toggle(toggle.title, isOn: binding(of: toggle))
                    }
                } header: {
                    Text(ObjectActionsScreen.toggleHeader)
                }
            }
        }
        .navigationTitle(screen.page.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(of toggle: ObjectActionsScreen.Toggle) -> Binding<Bool> {
        switch toggle {
        case .actionBarItemsInMenu: $settings.showsActionBarItemsInMenu
        case .actionBarLongPressItemsInMenu: $settings.showsActionBarLongPressItemsInMenu
        }
    }

    /// 行の右端の今の値は、iPhoneの設定アプリと同じく、アイコンを付けない灰色の名前だけにする。アイコンは選ぶリストにだけ出す。
    private func picker(_ label: String, selection: Binding<ObjectAction<Item>>) -> some View {
        Picker(selection: selection) {
            Section {
                Label(ObjectActionsScreen.openMenuTitle, systemImage: ObjectActionsScreen.openMenuSymbolName).tag(ObjectAction<Item>.menu)
                option(primary)
                if screen.actionBar != nil {
                    Label(ObjectAction<Item>.openActionBarTitle, systemImage: ObjectAction<Item>.openActionBarSymbolName).tag(ObjectAction<Item>.actionBar)
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

    /// iOSの設定アプリと同じく、名前と今の値を並べ、シェブロンで並びの画面へ入る。
    private func swipeRow(_ side: PostSwipeSide) -> some View {
        NavigationLink(value: side.page) {
            // 値が長くても、名前の右の1行に収めて末尾を省く。`LabeledContent`は値が長いと名前の下へ回すため、並べて組む。
            HStack {
                Text(side.title(isRightToLeft: layoutDirection == .rightToLeft))
                    .layoutPriority(1)
                Spacer()
                Text(side.layout(in: settings).swipeSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func option(_ item: Item) -> some View {
        Label(item.title, systemImage: item.symbolName).tag(ObjectAction<Item>.item(item))
    }

    private func name(of action: ObjectAction<Item>) -> String {
        switch action {
        case .menu: ObjectActionsScreen.openMenuTitle
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
    /// 対象の操作の画面でない`entity`を渡すと、何も並べない。
    init?(entity: ObjectEntity<Item>, settings: AppSettings) {
        guard let screen = ObjectActionsScreen(entity.page) else { return nil }
        self.init(screen: screen, settings: settings, actions: entity.actions(in: settings), primary: Item.primaryItem)
    }
}
