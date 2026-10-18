import SciaCore
import SwiftUI

/// 並びの設定画面に出す、項目の名前と印。
protocol MenuItemPresentable {
    var title: String { get }
    /// 名前の下に添える説明。
    var note: String? { get }
    var symbolName: String { get }
    /// 「その他」の境目の行の名前と説明と印。境目より下の項目をどこへ入れるかは、項目の種類ごとに違う。
    static var moreBoundaryTitle: String { get }
    static var moreBoundaryNote: String { get }
    static var moreBoundarySymbolName: String { get }
}

/// 長押しのメニューでは、境目より下の項目は「その他」のサブメニューに入る。
extension MenuItemPresentable {
    static var moreBoundaryTitle: String { "その他" }
    static var moreBoundaryNote: String { "これより下の項目は、メニューの「その他」の中に入ります" }
    static var moreBoundarySymbolName: String { "ellipsis.circle" }
}

extension StatusMenuItem: MenuItemPresentable {}
extension UserMenuItem: MenuItemPresentable {}

/// 長押しのメニューや投稿欄の＋の並びを変える画面。項目、区切り線、「その他」の境目を1本のリストで並べ替え、項目ごとに表示を切り替える。決まりはdocs/menus.mdにある。
struct MenuLayoutSettingsView<Item: MenuItemKind & MenuItemPresentable>: View {
    let title: String
    @Binding var layout: MenuLayout<Item>
    /// 区切り線は同じ値が並ぶため、リストで見分けるIDを行ごとに振る。
    @State private var rows: [Row]

    private struct Row: Identifiable {
        let id = UUID()
        var element: MenuLayout<Item>.Element
    }

    init(title: String, layout: Binding<MenuLayout<Item>>) {
        self.title = title
        _layout = layout
        _rows = State(initialValue: layout.wrappedValue.elements.map { Row(element: $0) })
    }

    var body: some View {
        List {
            Section {
                ForEach($rows) { $row in
                    rowView($row)
                        .deleteDisabled(row.element != .separator)
                }
                .onMove { source, destination in
                    rows.move(fromOffsets: source, toOffset: destination)
                    save()
                }
                .onDelete { offsets in
                    rows.remove(atOffsets: offsets)
                    save()
                }
            } footer: {
                Text("長押ししてドラッグすると並べ替えられます。区切り線はメニューの項目のまとまりを分け、左へスワイプすると消せます。")
            }
            Section {
                Button("区切り線を足す") {
                    // 足した区切り線が見つけやすいよう、「その他」のすぐ上に置く。
                    let index = rows.firstIndex { $0.element == .more } ?? rows.endIndex
                    rows.insert(Row(element: .separator), at: index)
                    save()
                }
                Button("最初の並びに戻す", role: .destructive) {
                    rows = Item.defaultLayout.elements.map { Row(element: $0) }
                    save()
                }
            }
        }
        // 別のウィンドウで同じ設定を変えたら、行も作り直す。古い行のまま保存すると、そちらの変更を上書きしてしまうため。
        .onChange(of: layout) { _, newValue in
            guard newValue.elements != rows.map(\.element) else { return }
            rows = newValue.elements.map { Row(element: $0) }
        }
        // 編集モードにはしない。編集モードのリストでは行のスイッチが押せなくなるため。並べ替えは長押しのドラッグで、区切り線の削除はスワイプでできる。
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func rowView(_ row: Binding<Row>) -> some View {
        switch row.wrappedValue.element {
        case .item(let item, let isVisible):
            Toggle(isOn: Binding {
                isVisible
            } set: { newValue in
                row.wrappedValue.element = .item(item, isVisible: newValue)
                save()
            }) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        if let note = item.note {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: item.symbolName)
                }
            }
        case .separator:
            HStack(spacing: 12) {
                line
                Text("区切り線")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                line
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("区切り線")
            // 行そのものが線なので、リストの行の線は出さない。出すと、リストが行の中の文字（真ん中の「区切り線」）に揃えて、線を途中から引いてしまう。
            .listRowSeparator(.hidden)
        case .more:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Item.moreBoundaryTitle)
                    Text(Item.moreBoundaryNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: Item.moreBoundarySymbolName)
            }
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1)
    }

    private func save() {
        layout = MenuLayout(elements: rows.map(\.element))
    }
}
