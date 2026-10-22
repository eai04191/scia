import SciaCore
import SwiftUI
import UIKit

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
    /// 区切り線を足せるか。
    static var supportsSeparators: Bool { get }
    /// 横並びの区切り線を足せるか。
    static var supportsRowSeparators: Bool { get }
    /// 表示する項目を1つは残すか。残すなら、最後の1つのスイッチを切れなくする。
    static var requiresVisibleItem: Bool { get }
}

/// 長押しのメニューでは、境目より下の項目は「その他」のサブメニューに入る。
extension MenuItemPresentable {
    static var moreBoundaryTitle: String { "その他" }
    static var moreBoundaryNote: String { "これより下の項目は、メニューの「その他」の中に入ります" }
    static var moreBoundarySymbolName: String { "ellipsis.circle" }
    static var supportsSeparators: Bool { true }
    static var supportsRowSeparators: Bool { true }
    static var requiresVisibleItem: Bool { false }
}

/// 長押しのメニューや投稿欄の＋の並びを変える画面。項目、区切り線、「その他」の境目を1本のリストで並べ替え、項目ごとに表示を切り替える。決まりはdocs/menus.mdにある。
/// 中身は`MenuLayoutViewController`で、UIKitのリストで作る。SwiftUIの`List`では、つまみは編集モードでしか出ず、編集モードでは行のスイッチが押せなくなるため、
/// スイッチを押せたまま、つまみをつかんですぐ並べ替えられる形にできない。
struct MenuLayoutSettingsView<Item: MenuItemKind & MenuItemPresentable>: View {
    let title: String
    @Binding var layout: MenuLayout<Item>

    var body: some View {
        MenuLayoutList(layout: $layout)
            .ignoresSafeArea()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MenuLayoutList<Item: MenuItemKind & MenuItemPresentable>: UIViewControllerRepresentable {
    @Binding var layout: MenuLayout<Item>

    func makeUIViewController(context: Context) -> MenuLayoutViewController<Item> {
        MenuLayoutViewController(layout: layout) { layout = $0 }
    }

    func updateUIViewController(_ controller: MenuLayoutViewController<Item>, context: Context) {
        controller.onChange = { layout = $0 }
        controller.update(layout)
    }
}

/// 汎用のクラスは、拡張でObjective-Cのプロトコルに準拠できないため、delegateのメソッドも本体に置く。
final class MenuLayoutViewController<Item: MenuItemKind & MenuItemPresentable>: UIViewController, UICollectionViewDelegate {
    var onChange: (MenuLayout<Item>) -> Void

    /// 区切り線は同じ値が並ぶため、リストで見分けるIDを行ごとに振る。
    private struct Row: Identifiable {
        let id = UUID()
        var element: MenuLayout<Item>.Element
    }

    private enum Section {
        case rows
        case actions
    }

    private enum Cell: Hashable {
        case row(UUID)
        case addSeparator
        case addRowSeparator
        case reset
    }

    private var rows: [Row]
    private var dataSource: UICollectionViewDiffableDataSource<Section, Cell>?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())

    /// メニューで横に並ぶ項目の数。これを超えた項目は、横並びの下にふだんの行として続く。
    private let rowCapacity = 3

    init(layout: MenuLayout<Item>, onChange: @escaping (MenuLayout<Item>) -> Void) {
        rows = layout.elements.map { Row(element: $0) }
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.hidesTopEdgeEffectOnMac()
        view.addSubview(collectionView)
        dataSource = makeDataSource()
        applySnapshot(animated: false)
    }

    /// 別のウィンドウで同じ設定を変えたら、行も作り直す。古い行のまま保存すると、そちらの変更を上書きしてしまうため。
    func update(_ layout: MenuLayout<Item>) {
        // 項目どうしの比べ方は、リストのように名前を含めないことがあるため、名前まで含む保存の形で比べる。
        guard layout.tokens != MenuLayout(defaultElements: rows.map(\.element)).tokens else { return }
        rows = layout.elements.map { Row(element: $0) }
        applySnapshot(animated: false)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.footerMode = .supplementary
        // 項目どうしの間だけに線を引く。区切り線の行は自分が線なので、その上下には引かない。
        configuration.itemSeparatorHandler = { [weak self] indexPath, separator in
            var separator = separator
            guard let self, indexPath.section == 0 else { return separator }
            let isSeparator = { (index: Int) in self.rows.indices.contains(index) && self.rows[index].element.isSeparator }
            if isSeparator(indexPath.item) || isSeparator(indexPath.item - 1) {
                separator.topSeparatorVisibility = .hidden
            }
            if isSeparator(indexPath.item) || isSeparator(indexPath.item + 1) {
                separator.bottomSeparatorVisibility = .hidden
            }
            return separator
        }
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, indexPath.section == 0, rows.indices.contains(indexPath.item), rows[indexPath.item].element.isSeparator else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "削除") { [weak self, id = rows[indexPath.item].id] _, _, completion in
                self?.removeRow(id: id)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [delete])
        }
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, Cell> {
        let rowRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
            guard let self, let row = rows.first(where: { $0.id == id }) else { return }
            configure(cell, for: row)
        }
        let actionRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Cell> { cell, _, item in
            var content = UIListContentConfiguration.cell()
            switch item {
            case .addSeparator:
                content.text = "区切り線を足す"
                content.textProperties.color = .tintColor
            case .addRowSeparator:
                content.text = "横並びの区切り線を足す"
                content.textProperties.color = .tintColor
            case .reset:
                content.text = "最初の並びに戻す"
                content.textProperties.color = .systemRed
            case .row:
                break
            }
            cell.contentConfiguration = content
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { footer, _, indexPath in
            var content = UIListContentConfiguration.footer()
            if indexPath.section == 0 {
                content.text = if !Item.supportsSeparators {
                    "右のつまみをドラッグすると並べ替えられます。"
                } else if Item.supportsRowSeparators {
                    "右のつまみをドラッグすると並べ替えられます。区切り線はメニューの項目のまとまりを分け、左へスワイプすると消せます。横並びの区切り線より下のまとまりは、メニューの中で横に並びます。"
                } else {
                    "右のつまみをドラッグすると並べ替えられます。区切り線はメニューの項目のまとまりを分け、左へスワイプすると消せます。"
                }
            }
            footer.contentConfiguration = content
        }

        let dataSource = UICollectionViewDiffableDataSource<Section, Cell>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .row(let id):
                collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: id)
            case .addSeparator, .addRowSeparator, .reset:
                collectionView.dequeueConfiguredReusableCell(using: actionRegistration, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        dataSource.reorderingHandlers.canReorderItem = { item in
            if case .row = item { true } else { false }
        }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            rows = transaction.finalSnapshot.itemIdentifiers(inSection: .rows).compactMap { cell in
                if case .row(let id) = cell { rowsByID[id] } else { nil }
            }
            save()
            refreshDependentRows()
        }
        return dataSource
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        let reorder = UICellAccessory.reorder(displayed: .always, options: .init(showsVerticalSeparator: false))
        switch row.element {
        case .item(let item, let isVisible):
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.title
            content.secondaryText = item.note
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.image = UIImage(systemName: item.symbolName)
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = isVisible
            toggle.isEnabled = !(Item.requiresVisibleItem && isVisible && visibleItemCount == 1)
            toggle.addAction(UIAction { [weak self, id = row.id] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.setVisible(toggle.isOn, id: id)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing())), reorder]
        case .separator:
            cell.contentConfiguration = UIHostingConfiguration { SeparatorRow() }
            cell.accessories = [reorder]
        case .rowSeparator:
            let count = visibleItemCount(after: row.id)
            cell.contentConfiguration = UIHostingConfiguration { RowSeparatorRow(count: count, capacity: rowCapacity) }
            cell.accessories = [reorder]
        case .more:
            var content = UIListContentConfiguration.subtitleCell()
            content.text = Item.moreBoundaryTitle
            content.secondaryText = Item.moreBoundaryNote
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.image = UIImage(systemName: Item.moreBoundarySymbolName)
            cell.contentConfiguration = content
            cell.accessories = [reorder]
        }
    }

    /// 横並びの知らせは、まとまりの項目の数で出たり消えたりして行の高さが変わるため、行を足したり消したりし終わってから描き直す。
    /// 同じ`apply`で描き直すと、足したり消したりする行が動かずに一度に入れ替わる。
    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Cell>()
        snapshot.appendSections([.rows, .actions])
        snapshot.appendItems(rows.map { .row($0.id) }, toSection: .rows)
        let actions: [Cell] = if !Item.supportsSeparators {
            [.reset]
        } else if Item.supportsRowSeparators {
            [.addSeparator, .addRowSeparator, .reset]
        } else {
            [.addSeparator, .reset]
        }
        snapshot.appendItems(actions, toSection: .actions)
        dataSource?.apply(snapshot, animatingDifferences: animated) { [weak self] in self?.refreshRowSeparatorNotes() }
    }

    /// 横並びの知らせと行どうしの線は、ほかの行の並びや表示で変わるため、並びが変わるたびに描き直す。
    private func refreshDependentRows() {
        refreshRowSeparatorNotes()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    /// 横並びの知らせは、まとまりの項目の表示を切り替えても変わる。
    /// data sourceへの`apply`で描き直すと、ほかの行のスイッチまで以後のタップに反応しなくなったため、見えているセルを直接描き直す。
    /// 見えていない行は、出てくるときに今の行から作られる。
    /// 知らせが出たり消えたりすると行の高さが変わるため、下の行が一度に跳ねないよう、伸び縮みを動かす。
    private func refreshRowSeparatorNotes() {
        // 視差効果を減らす設定では動かさない（docs/vision.mdの「一覧の動き」）。
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : AppDependencies.tuning.value(of: TuningCatalog.menuLayoutNoteDuration)
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) { [self] in
            for row in rows where row.element == .rowSeparator {
                guard let indexPath = dataSource?.indexPath(for: .row(row.id)),
                      let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell else { continue }
                configure(cell, for: row)
            }
            collectionView.layoutIfNeeded()
        }
    }

    /// 横並びの区切り線から、次の区切り線か「その他」の境目までにある、表示する項目の数。
    private func visibleItemCount(after id: UUID) -> Int {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return 0 }
        var count = 0
        for next in rows[(index + 1)...] {
            switch next.element {
            case .item(_, let isVisible): if isVisible { count += 1 }
            case .separator, .rowSeparator, .more: return count
            }
        }
        return count
    }

    private func setVisible(_ isVisible: Bool, id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }), case .item(let item, _) = rows[index].element else { return }
        rows[index].element = .item(item, isVisible: isVisible)
        save()
        refreshRowSeparatorNotes()
        if Item.requiresVisibleItem {
            refreshItemSwitches()
        }
    }

    /// 表示する項目の数。
    private var visibleItemCount: Int {
        rows.count { if case .item(_, true) = $0.element { true } else { false } }
    }

    /// 最後の1つのスイッチを切れなくするため、表示の切り替えのたびに、見えている項目の行を描き直す。
    /// `refreshRowSeparatorNotes`と同じく、data sourceへの`apply`ではなく見えているセルを直接描き直す。
    private func refreshItemSwitches() {
        for row in rows {
            guard case .item = row.element,
                  let indexPath = dataSource?.indexPath(for: .row(row.id)),
                  let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell else { continue }
            configure(cell, for: row)
        }
    }

    private func removeRow(id: UUID) {
        rows.removeAll { $0.id == id }
        save()
        applySnapshot(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func insert(_ element: MenuLayout<Item>.Element, at index: Int) {
        rows.insert(Row(element: element), at: index)
        save()
        applySnapshot(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func save() {
        onChange(MenuLayout(elements: rows.map(\.element)))
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource?.itemIdentifier(for: indexPath) {
        // 足した区切り線は、押したボタンのすぐ上に出るよう、並びのいちばん下に置く。ほかの場所に置くと、画面の外に入って、どこに足されたか分からないことがある。
        case .addSeparator:
            insert(.separator, at: rows.endIndex)
        case .addRowSeparator:
            insert(.rowSeparator, at: rows.endIndex)
        case .reset:
            rows = Item.defaultLayout.elements.map { Row(element: $0) }
            save()
            applySnapshot(animated: !UIAccessibility.isReduceMotionEnabled)
        case .row, nil:
            break
        }
    }

    /// 並べ替えは並びの中だけで行い、下のボタンの間には入れない。
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard proposedIndexPath.section != 0 else { return proposedIndexPath }
        return IndexPath(item: rows.count - 1, section: 0)
    }
}

private struct SeparatorRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SeparatorLine()
            Text("区切り線")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize()
            SeparatorLine()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("区切り線")
    }
}

private struct RowSeparatorRow: View {
    let count: Int
    let capacity: Int

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                SeparatorLine()
                Label("横並び", systemImage: "rectangle.split.3x1")
                    // リストの行の中では、指定しないとアイコンだけになる。
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                SeparatorLine()
            }
            if count > capacity {
                Text("横に並ぶのは\(capacity)個までです。\(capacity + 1)個目からは、その下にふだんの行で出ます")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > capacity ? "横並びの区切り線。横に並ぶのは\(capacity)個までです" : "横並びの区切り線")
    }
}

private struct SeparatorLine: View {
    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1)
    }
}

private extension MenuLayout.Element {
    /// 区切り線の仲間か。行どうしの線を引かず、スワイプで消せる。
    var isSeparator: Bool {
        switch self {
        case .separator, .rowSeparator: true
        case .item, .more: false
        }
    }
}
