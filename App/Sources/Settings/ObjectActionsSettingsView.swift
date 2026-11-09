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
    /// 左右のスワイプの並びの画面の入り口。投稿でだけ渡す。
    var swipes: PostSwipeSettingsSection?
    /// メニューとアクションバーの入り口の下に置くスイッチの節。投稿では、アクションバーを出している投稿のメニューに何を出すかを置く。
    var toggles: SettingsToggleSection?

    @Environment(\.layoutDirection) private var layoutDirection

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
            if let swipes {
                Section {
                    swipeRow(.leading, swipes: swipes)
                    swipeRow(.trailing, swipes: swipes)
                }
            }
            if let toggles {
                Section {
                    ForEach(toggles.toggles.indices, id: \.self) { index in
                        Toggle(toggles.toggles[index].title, isOn: toggles.toggles[index].isOn)
                    }
                } header: {
                    Text(toggles.header)
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
    private func swipeRow(_ side: PostSwipeSide, swipes: PostSwipeSettingsSection) -> some View {
        NavigationLink(value: side == .leading ? SettingsPage.statusLeadingSwipe : SettingsPage.statusTrailingSwipe) {
            // 値が長くても、名前の右の1行に収めて末尾を省く。`LabeledContent`は値が長いと名前の下へ回すため、並べて組む。
            HStack {
                Text(PostSwipeSettingsSection.title(of: side, in: layoutDirection))
                    .layoutPriority(1)
                Spacer()
                Text(swipes.summary(of: side))
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
    init(entity: ObjectEntity<Item>, settings: AppSettings, menu: SettingsPage?, actionBar: SettingsPage? = nil, swipes: PostSwipeSettingsSection? = nil, toggles: SettingsToggleSection? = nil) {
        self.init(title: entity.title, actions: entity.actions(in: settings), menu: menu, primary: Item.primaryItem, actionBar: actionBar, swipes: swipes, toggles: toggles)
    }
}

/// 投稿の操作の画面の、左右のスワイプの行。決まりはdocs/object-actions.mdの「設定画面」にある。
struct PostSwipeSettingsSection {
    let leading: MenuLayout<PostSwipeItem>
    let trailing: MenuLayout<PostSwipeItem>

    /// iOSのメールの「スワイプオプション」と同じ名前。先頭の側は、左から右へ書く言語では右にスワイプして出す。
    static func title(of side: PostSwipeSide, in direction: LayoutDirection) -> String {
        switch (side, direction) {
        case (.leading, .leftToRight), (.trailing, .rightToLeft): "右にスワイプ"
        default: "左にスワイプ"
        }
    }

    /// 行の値。割り当てた項目の名前を並べる。
    func summary(of side: PostSwipeSide) -> String {
        let items = switch side {
        case .leading: leading.swipeItems
        case .trailing: trailing.swipeItems
        }
        return items.isEmpty ? "なし" : items.map(\.title).formatted(.list(type: .and, width: .narrow))
    }
}

/// 見出しを共有する、スイッチを並べた節。
struct SettingsToggleSection {
    struct Toggle {
        let title: String
        let isOn: Binding<Bool>
    }

    let header: String
    let toggles: [Toggle]
}
