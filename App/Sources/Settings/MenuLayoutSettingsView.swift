import SciaCore
import SwiftUI
import UIKit

/// 長押しのメニューや投稿欄の＋の並びを変える画面。項目、区切り線、「その他」の境目を1本のリストで並べ替え、項目ごとに表示を切り替える。決まりはdocs/menus.mdにある。
/// 中身は`MenuLayoutViewController`で、UIKitのリストで作る。SwiftUIの`List`では、つまみは編集モードでしか出ず、編集モードでは行のスイッチが押せなくなるため、
/// スイッチを押せたまま、つまみをつかんですぐ並べ替えられる形にできない。
struct MenuLayoutSettingsView<Item: MenuItemKind & MenuItemPresentable>: View {
    let title: String
    @Binding var layout: MenuLayout<Item>
    /// 項目の記号の代わりに出す画像。タブに置いたプロフィールのその人のアイコン。nilなら項目の記号を出す。
    var image: (Item) -> UIImage? = { _ in nil }
    /// `image`の返す画像が変わるたびに変わる値。変わったら行を描き直す。読んだ値の変化をSwiftUIが追えるよう、描くときに読む。
    var imageRevision: () -> Int = { 0 }
    /// 並びの下に、並びとは別に置くスイッチ。
    var options: [MenuLayoutOption] = []
    /// 並びのすぐ下に置くボタン。タブの並びの「リストを作成」。
    var actions: [MenuLayoutAction] = []
    /// 左へスワイプして消せる項目。タブの並びのリスト。
    var itemDeletion: MenuLayoutItemDeletion<Item>?

    var body: some View {
        MenuLayoutList(layout: $layout, image: image, imageRevision: imageRevision(), options: options, actions: actions, itemDeletion: itemDeletion)
            .ignoresSafeArea()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// 並びのすぐ下に置くボタン。押したときの処理は、画面を作る側が決める。
struct MenuLayoutAction {
    let title: String
    let symbolName: String
    let handler: @MainActor () -> Void
}

/// 並びの項目を左へスワイプして消す。消すかどうかを確かめるのも、並びから外すのも、画面を作る側が行う。
/// 並びの行は、外されて並びが変わったときに消える。
struct MenuLayoutItemDeletion<Item> {
    let canDelete: (Item) -> Bool
    /// 並びの下の説明に添える文。
    let footer: String
    let delete: @MainActor (Item) -> Void
}

/// 並びの画面に、並びとは別に置くスイッチ。1つずつ欄を分け、欄の下に説明を添える。
/// スイッチの表示は行を作るときに読む。同じ画面を別のウインドウでも開いて片方で切り替えると、もう片方は開き直すまで前の表示のまま残る。
/// 窓を並べられるMacとiPadでしか起きず、並びの行のように別の窓の変更を受けて描き直す作りを足す手間に見合わないため、扱わない。
struct MenuLayoutOption {
    let title: String
    let footer: String
    let isOn: Binding<Bool>
}

private struct MenuLayoutList<Item: MenuItemKind & MenuItemPresentable>: UIViewControllerRepresentable {
    @Binding var layout: MenuLayout<Item>
    let image: (Item) -> UIImage?
    let imageRevision: Int
    let options: [MenuLayoutOption]
    let actions: [MenuLayoutAction]
    let itemDeletion: MenuLayoutItemDeletion<Item>?

    func makeUIViewController(context: Context) -> MenuLayoutViewController<Item> {
        MenuLayoutViewController(layout: layout, image: image, imageRevision: imageRevision, options: options, actions: actions, itemDeletion: itemDeletion) { layout = $0 }
    }

    func updateUIViewController(_ controller: MenuLayoutViewController<Item>, context: Context) {
        controller.onChange = { layout = $0 }
        controller.update(layout)
        controller.setImageRevision(imageRevision)
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

    private enum Section: Hashable {
        case rows
        case actions
        /// `options`の何番目のスイッチか。
        case option(Int)
    }

    private enum Cell: Hashable {
        case row(UUID)
        /// `actions`の何番目のボタンか。
        case action(Int)
        case addSeparator
        case addRowSeparator
        case reset
        case option(Int)
    }

    private var rows: [Row]
    /// 並べ替えたあと、画面の外にあってまだ線を引き直していない行。
    private var rowsWithStaleSeparators: Set<UUID> = []
    private var dataSource: UICollectionViewDiffableDataSource<Section, Cell>?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())

    /// メニューで横に並ぶ項目の数。これを超えた項目は、横並びの下にふだんの行として続く。
    private let rowCapacity = 3

    /// 項目の記号の代わりに出す画像。nilなら項目の記号を出す。
    private let image: (Item) -> UIImage?
    private var imageRevision: Int
    private let options: [MenuLayoutOption]
    private let actions: [MenuLayoutAction]
    private let itemDeletion: MenuLayoutItemDeletion<Item>?

    init(
        layout: MenuLayout<Item>,
        image: @escaping (Item) -> UIImage?,
        imageRevision: Int,
        options: [MenuLayoutOption],
        actions: [MenuLayoutAction],
        itemDeletion: MenuLayoutItemDeletion<Item>?,
        onChange: @escaping (MenuLayout<Item>) -> Void
    ) {
        rows = layout.elements.map { Row(element: $0) }
        self.image = image
        self.imageRevision = imageRevision
        self.options = options
        self.actions = actions
        self.itemDeletion = itemDeletion
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

    /// `image`の返す画像が変わったら、項目の行を描き直す。
    func setImageRevision(_ revision: Int) {
        guard revision != imageRevision else { return }
        imageRevision = revision
        guard let dataSource else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(rows.compactMap { row in
            if case .item = row.element { .row(row.id) } else { nil }
        })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.footerMode = .supplementary
        // 項目どうしの間だけに線を引く。区切り線の行は自分が線なので、その上下には引かない。
        configuration.itemSeparatorHandler = { [weak self] indexPath, separator in
            var separator = separator
            guard let self, indexPath.section == 0 else { return separator }
            let hidden = Self.hiddenSeparators(at: indexPath.item, in: rows)
            if hidden.top {
                separator.topSeparatorVisibility = .hidden
            }
            if hidden.bottom {
                separator.bottomSeparatorVisibility = .hidden
            }
            return separator
        }
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, indexPath.section == 0, rows.indices.contains(indexPath.item) else { return nil }
            let element = rows[indexPath.item].element
            if case .item(let item, _) = element, let itemDeletion, itemDeletion.canDelete(item) {
                // 消すのは確かめてサーバーが受け付けてからなので、スワイプした行はいったん戻す。
                let delete = UIContextualAction(style: .destructive, title: "削除") { _, _, completion in
                    itemDeletion.delete(item)
                    completion(false)
                }
                return UISwipeActionsConfiguration(actions: [delete])
            }
            guard element.isSeparator else { return nil }
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
        let actionRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Cell> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.cell()
            switch item {
            case .action(let index):
                guard let action = self?.actions[index] else { break }
                content.text = action.title
                content.image = UIImage(systemName: action.symbolName)
                content.textProperties.color = .tintColor
            case .addSeparator:
                content.text = "区切り線を足す"
                content.textProperties.color = .tintColor
            case .addRowSeparator:
                content.text = "横並びの区切り線を足す"
                content.textProperties.color = .tintColor
            case .reset:
                content.text = "最初の並びに戻す"
                content.textProperties.color = .systemRed
            case .row, .option:
                break
            }
            cell.contentConfiguration = content
        }
        let optionRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { [weak self] cell, _, index in
            guard let option = self?.options[index] else { return }
            var content = UIListContentConfiguration.cell()
            content.text = option.title
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = option.isOn.wrappedValue
            toggle.addAction(UIAction { action in
                guard let toggle = action.sender as? UISwitch else { return }
                option.isOn.wrappedValue = toggle.isOn
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] footer, _, indexPath in
            var content = UIListContentConfiguration.footer()
            if case .option(let index) = self?.dataSource?.sectionIdentifier(for: indexPath.section) {
                content.text = self?.options[index].footer
            } else if indexPath.section == 0 {
                let base = if !Item.supportsSeparators {
                    "右のつまみをドラッグすると並べ替えられます。"
                } else if Item.supportsRowSeparators {
                    "右のつまみをドラッグすると並べ替えられます。区切り線はメニューの項目のまとまりを分け、左へスワイプすると消せます。横並びの区切り線より下のまとまりは、メニューの中で横に並びます。"
                } else {
                    "右のつまみをドラッグすると並べ替えられます。区切り線はメニューの項目のまとまりを分け、左へスワイプすると消せます。"
                }
                content.text = [base, self?.itemDeletion?.footer].compactMap(\.self).joined()
            }
            footer.contentConfiguration = content
        }

        let dataSource = UICollectionViewDiffableDataSource<Section, Cell>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .row(let id):
                collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: id)
            case .action, .addSeparator, .addRowSeparator, .reset:
                collectionView.dequeueConfiguredReusableCell(using: actionRegistration, for: indexPath, item: item)
            case .option(let index):
                collectionView.dequeueConfiguredReusableCell(using: optionRegistration, for: indexPath, item: index)
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
            content.image = image(item) ?? UIImage(systemName: item.symbolName)
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
        let buttons: [Cell] = if !Item.supportsSeparators {
            [.reset]
        } else if Item.supportsRowSeparators {
            [.addSeparator, .addRowSeparator, .reset]
        } else {
            [.addSeparator, .reset]
        }
        snapshot.appendItems(actions.indices.map(Cell.action) + buttons, toSection: .actions)
        for index in options.indices {
            snapshot.appendSections([.option(index)])
            snapshot.appendItems([.option(index)], toSection: .option(index))
        }
        dataSource?.apply(snapshot, animatingDifferences: animated) { [weak self] in self?.refreshRowSeparatorNotes() }
    }

    /// 横並びの知らせと行どうしの線は、ほかの行の並びや表示で変わるため、並びが変わるたびに描き直す。
    /// 線は、すべての行に大きさを測り直させて引き直す。並べ替えている間、一覧は途中の並びの位置で線の出方を聞くが、`rows`は指を離すまで元の並びなので、ほかの行の出方で引いてしまう。
    /// 区切り線の行が動くと、その行は前後とも上下に線を引かないままなのに、下の行の出方で線を引いて残るため、出方が変わった行に絞らない。
    /// レイアウトを無効にすると、無効にする行を絞っても画面の外の行の測った高さが見積もりの高さに戻って一覧の高さが縮み、
    /// 下のほうまでスクロールしていると、指を離した直後に持ち上げていた行が離れた位置に描かれ、そこから跳ねて戻るため、行に測り直させる。
    /// 画面の外の行はセルがなく測り直させられないので、画面に入るときに測り直させる。
    private func refreshDependentRows() {
        refreshRowSeparatorNotes()
        for index in rows.indices {
            if let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) {
                cell.invalidateIntrinsicContentSize()
            } else {
                rowsWithStaleSeparators.insert(rows[index].id)
            }
        }
    }

    /// 行の上と下に、行どうしの線を引かないか。区切り線の行は自分が線なので、その行と上下の行には引かない。
    private static func hiddenSeparators(at index: Int, in rows: [Row]) -> HiddenSeparators {
        let isSeparator = { (index: Int) in rows.indices.contains(index) && rows[index].element.isSeparator }
        return HiddenSeparators(
            top: isSeparator(index) || isSeparator(index - 1),
            bottom: isSeparator(index) || isSeparator(index + 1)
        )
    }

    private struct HiddenSeparators: Equatable {
        var top: Bool
        var bottom: Bool
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

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.section == 0, rows.indices.contains(indexPath.item),
              rowsWithStaleSeparators.remove(rows[indexPath.item].id) != nil else { return }
        cell.invalidateIntrinsicContentSize()
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
        case .action(let index):
            actions[index].handler()
        case .reset:
            rows = Item.defaultLayout.elements.map { Row(element: $0) }
            save()
            applySnapshot(animated: !UIAccessibility.isReduceMotionEnabled)
        case .row, .option, nil:
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
