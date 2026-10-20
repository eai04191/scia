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

/// 長押しのメニューや投稿欄の＋の並びを変える画面。項目、区切り線、「その他」の境目を1本のリストで並べ替え、項目ごとに表示を切り替える。決まりはdocs/menus.mdにある。
struct MenuLayoutSettingsView<Item: MenuItemKind & MenuItemPresentable>: View {
    let title: String
    @Binding var layout: MenuLayout<Item>
    /// 区切り線は同じ値が並ぶため、リストで見分けるIDを行ごとに振る。
    @State private var rows: [Row]
    /// 行の中での、項目の名前の左端の位置。行どうしの線をここから引き、リストの標準の線と同じ位置に揃える。
    @State private var lineLeading: CGFloat = 0
    /// リストの標準の行と同じ余白。リストの上下の余白を0にして、同じ量を行の中身に持たせ、中身の下端を行の下端に揃える。
    private let rowInsets = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var element: MenuLayout<Item>.Element
    }

    /// 項目どうしの間だけに線を引く。区切り線の行は自分が線なので、その上下には引かない。いちばん下の行にも引かない。
    private var rowsWithBottomLine: Set<Row.ID> {
        Set(zip(rows, rows.dropFirst()).compactMap { row, next in
            row.element != .separator && next.element != .separator ? row.id : nil
        })
    }

    init(title: String, layout: Binding<MenuLayout<Item>>) {
        self.title = title
        _layout = layout
        _rows = State(initialValue: layout.wrappedValue.elements.map { Row(element: $0) })
    }

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    rowView(binding(for: row))
                        // スイッチのない行（「その他」の境目）も横いっぱいに広げ、線の右端を揃える。
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .coordinateSpace(.named(Self.rowSpace))
                        .padding(.vertical, rowInsets.top)
                        .overlay(alignment: .bottomLeading) {
                            if rowsWithBottomLine.contains(row.id) {
                                line.padding(.leading, lineLeading)
                            }
                        }
                        // 行どうしの線は、リストの線を使わずに、行の中身の下端に自分で引く。
                        // リストの線や行の背景（listRowBackground）は、リストが行ごとの設定として持っていて、並べ替えや削除のあとに隣の行の設定を組み直さないことがあり、
                        // 出ないはずの線が残ったり、出るはずの線が消えたりした。行を作り直して組み直させると、項目がちらついた。
                        // 画面での位置を測って境目に引く形も、削除や並べ替えでリストが行を動かしたときに位置が測り直されず、線がずれて隠れた。
                        // 中身の下端を行の下端に揃えれば、位置を測らずに済み、線は行と一緒に動く。
                        .listRowInsets(EdgeInsets(top: 0, leading: rowInsets.leading, bottom: 0, trailing: rowInsets.trailing))
                        .listRowSeparator(.hidden)
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
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rowSpace)).minX } action: { lineLeading = $0 }
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

    /// 行のスイッチから`rows`の同じ行を書き換える。並べ替えたあとも、IDで行を探す。
    private func binding(for row: Row) -> Binding<Row> {
        Binding {
            rows.first { $0.id == row.id } ?? row
        } set: { newValue in
            guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
            rows[index] = newValue
        }
    }

    private nonisolated static var rowSpace: String { "row" }

    private let lineThickness: CGFloat = 1

    private var line: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: lineThickness)
    }

    private func save() {
        layout = MenuLayout(elements: rows.map(\.element))
    }
}
