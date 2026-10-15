import os
import SciaCore
import UIKit

/// 投稿欄の入力欄の上に、添付したメディアを同じ大きさの正方形のサムネイルで横一列に並べる。
/// 上限が4枚より多いサーバーでも1段のまま並べ、収まらない分は横にスクロールする。
///
/// 並べ替えはドラッグ&ドロップで行う。iOS 15からはiPhoneでもコレクションビューのドラッグが既定で有効になっている。
/// VoiceOverとキーボードのために、同じ操作を「前へ移動」「後ろへ移動」として、セルのカスタムアクションと長押しのメニューにも置く。
@MainActor
final class ComposeAttachmentStrip: UIView {
    /// サムネイルの一辺。
    static let itemSize: CGFloat = 64
    /// サムネイルを読み込む大きさ。iPhoneの画面の倍率の最大（3倍）に合わせる。
    static let thumbnailPixelSize = itemSize * 3

    /// サムネイルを押したときに呼ぶ。
    var onSelect: (DraftAttachment.ID) -> Void = { _ in }
    /// 並べ替えたときに、移した添付と移した先の位置を渡して呼ぶ。
    var onMove: (DraftAttachment.ID, Int) -> Void = { _, _ in }
    /// 長押しのメニューを出す直前と、閉じ始めたときに呼ぶ。メニューの間、iOSはソフトウェアキーボードを隠す。
    var onContextMenuWillShow: () -> Void = {}
    var onContextMenuWillEnd: () -> Void = {}

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, DraftAttachment.ID>?
    private var items: [DraftAttachment.ID: Item] = [:]

    struct Item {
        let attachment: DraftAttachment
        let local: LocalMedia?
        let status: ComposeAttachmentStatus
    }

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: Self.itemSize, height: Self.itemSize)
        layout.minimumLineSpacing = 8
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = false
        collectionView.clipsToBounds = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: Self.itemSize),
        ])
        let registration = UICollectionView.CellRegistration<ComposeAttachmentCell, DraftAttachment.ID> { [weak self] cell, indexPath, id in
            guard let self, let item = self.items[id] else { return }
            cell.configure(item, moveActions: self.moveActions(for: id, at: indexPath.item))
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, DraftAttachment.ID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        // ドロップしたら、データソースが並びを当て直してから知らせてくる。
        dataSource.reorderingHandlers.canReorderItem = { _ in true }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.didReorder(transaction)
        }
        self.dataSource = dataSource
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 並びと各サムネイルの状態を描き直す。足したものは後ろに付け、並びの変わらないものは中身だけ描き直す。
    func update(_ newItems: [Item]) {
        items = Dictionary(uniqueKeysWithValues: newItems.map { ($0.attachment.id, $0) })
        guard let dataSource else { return }
        let ids = newItems.map(\.attachment.id)
        var snapshot = NSDiffableDataSourceSnapshot<Int, DraftAttachment.ID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        // 並べ替えで位置が変わると、前へ・後ろへの移動の項目も変わるため、残っているものはすべて描き直す。
        snapshot.reconfigureItems(ids.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: window != nil)
    }

    /// 添付のサムネイル。ビューアを開くときと閉じるときに、拡大と縮小の起点にする。列を出していないか、セルが画面にないときはnil。
    func tile(for id: DraftAttachment.ID) -> MediaTileView? {
        guard window != nil, !isHidden, let indexPath = dataSource?.indexPath(for: id),
              let cell = collectionView.cellForItem(at: indexPath) as? ComposeAttachmentCell
        else { return nil }
        return cell.tile
    }

    /// 添付を見える位置までスクロールする。ビューアを閉じるとき、戻り先のサムネイルが列の外にあると、画像を薄くして消すしかないため。
    func scrollToItem(_ id: DraftAttachment.ID) {
        guard let indexPath = dataSource?.indexPath(for: id) else { return }
        collectionView.scrollToItem(at: indexPath, at: [], animated: false)
    }

    private var itemCount: Int {
        dataSource?.snapshot().numberOfItems ?? 0
    }

    /// 前へ・後ろへの移動。端にあって動かせない向きは含めない。
    private func moveActions(for id: DraftAttachment.ID, at index: Int) -> [MoveAction] {
        var actions: [MoveAction] = []
        if index > 0 {
            actions.append(MoveAction(title: "前へ移動", systemImage: "arrow.left") { [weak self] in self?.onMove(id, index - 1) })
        }
        if index < itemCount - 1 {
            actions.append(MoveAction(title: "後ろへ移動", systemImage: "arrow.right") { [weak self] in self?.onMove(id, index + 1) })
        }
        return actions
    }

    /// ドロップで並びが変わった。移したものは、差分のうち挿し込んだ位置にあるもの。
    private func didReorder(_ transaction: NSDiffableDataSourceTransaction<Int, DraftAttachment.ID>) {
        for change in transaction.difference.insertions {
            guard case .insert(let offset, let id, _) = change else { continue }
            SciaLog.logger(category: "compose").info("attachment reordered by drop to=\(offset, privacy: .public)")
            onMove(id, offset)
        }
    }
}

/// 前へ・後ろへの移動の操作。セルのカスタムアクションと長押しのメニューで同じものを出す。
private struct MoveAction {
    let title: String
    let systemImage: String
    let handler: () -> Void
}

extension ComposeAttachmentStrip: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
        onSelect(id)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        onContextMenuWillShow()
    }

    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        onContextMenuWillEnd()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        let actions = moveActions(for: id, at: indexPath.item)
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: actions.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in action.handler() }
            })
        })
    }
}

extension ComposeAttachmentStrip: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = id
        return [item]
    }

    /// 並べ替えのためだけのドラッグなので、ほかのアプリへは渡さない。
    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool {
        true
    }

    /// 持ち上げたサムネイルの影を、角の丸い枠に合わせる。
    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        roundedPreviewParameters()
    }

    func collectionView(_ collectionView: UICollectionView, dropPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        roundedPreviewParameters()
    }

    private func roundedPreviewParameters() -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(
            roundedRect: CGRect(x: 0, y: 0, width: Self.itemSize, height: Self.itemSize),
            cornerRadius: MediaGridView.cornerRadius
        )
        return parameters
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        guard collectionView.hasActiveDrag else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    /// 並びの当て直しは、データソースの並べ替えの仕組みが行い、`didReorder`で知らせてくる。
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {}
}

/// 添付したメディア1つのサムネイル。タイムラインと同じ`MediaTileView`に、アップロードと代替テキストの送信の状態を重ねて見せる。
/// ビューアはこのサムネイルとのあいだで画像を動かす。
private final class ComposeAttachmentCell: UICollectionViewCell {
    let tile = MediaTileView(store: AppDependencies.mediaImages)
    /// 状態の表示を、サムネイルと同じ角の丸い枠に収める。
    private let overlay = UIView()
    /// 送信中と変換待ちの間、サムネイルを少し暗くする。
    private let dimView = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureView = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    /// 代替テキストの送信中に、ALTの札の位置に出す小さな回る表示。
    private let descriptionSpinner = UIActivityIndicatorView(style: .medium)
    /// 代替テキストを送れなかったときに、ALTの札の位置に出す印。
    private let descriptionFailureView = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 押したことはセルの選択で受けるため、サムネイル自身には触れさせない。
        tile.isUserInteractionEnabled = false
        tile.isAccessibilityElement = false
        overlay.isUserInteractionEnabled = false
        overlay.layer.cornerRadius = MediaGridView.cornerRadius
        overlay.layer.cornerCurve = .continuous
        overlay.clipsToBounds = true
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        spinner.color = .white
        descriptionSpinner.color = .white
        descriptionSpinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        // 感嘆符を白、円を赤で描き、どんなサムネイルの上でも見分けられるようにする。
        let failureColors = UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
        failureView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24).applying(failureColors)
        descriptionFailureView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16).applying(failureColors)
        for view in [tile, overlay] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        for view in [dimView, spinner, failureView, descriptionSpinner, descriptionFailureView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(view)
        }
        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: overlay.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            failureView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            failureView.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            // ALTの札と同じ左下に置く。
            descriptionSpinner.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 2),
            descriptionSpinner.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -2),
            descriptionFailureView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 5),
            descriptionFailureView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -5),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ item: ComposeAttachmentStrip.Item, moveActions: [MoveAction]) {
        let description = item.attachment.description
        let showsDescriptionState = item.status == .sendingDescription || item.status == .descriptionFailed
        // 代替テキストの送信中と失敗は、ALTの札の位置に状態を出すため、札を出さない。
        tile.applyLocal(thumbnail: item.local?.thumbnail, kind: item.local?.file?.kind, description: showsDescriptionState ? "" : description)
        // 送信の進み具合はまだ受け取っていないので、送信中も変換待ちと同じ回る表示にする。
        let isWorking = item.status == .uploading || item.status == .processing
        dimView.isHidden = !isWorking
        setAnimating(spinner, isWorking)
        failureView.isHidden = item.status != .failed
        setAnimating(descriptionSpinner, item.status == .sendingDescription)
        descriptionFailureView.isHidden = item.status != .descriptionFailed
        let kindName = item.local?.file.map { MediaTileView.kindName(of: $0.kind) } ?? "メディア"
        accessibilityLabel = [kindName, description].filter { !$0.isEmpty }.joined(separator: "、")
        accessibilityValue = switch item.status {
        case .uploading: "アップロード中"
        case .processing: "サーバーで処理中"
        case .ready: nil
        case .sendingDescription: "代替テキストを送信中"
        case .failed: "アップロードできませんでした"
        case .descriptionFailed: "代替テキストを送信できませんでした"
        }
        accessibilityTraits = .button
        accessibilityHint = "開いて代替テキストを編集できます。"
        accessibilityCustomActions = moveActions.map { action in
            UIAccessibilityCustomAction(name: action.title) { _ in
                action.handler()
                return true
            }
        }
    }

    private func setAnimating(_ spinner: UIActivityIndicatorView, _ animating: Bool) {
        if animating {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }
}
