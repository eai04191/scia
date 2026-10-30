import os
import SciaCore
import UIKit

/// 投稿欄の入力欄の上に、添付したメディアを同じ大きさの正方形のサムネイルで横一列に並べる。
/// 上限が4枚より多いサーバーでも1段のまま並べ、収まらない分は横にスクロールする。
///
/// 並べ替えはドラッグ&ドロップで行う。iOS 15からはiPhoneでもコレクションビューのドラッグが既定で有効になっている。
/// VoiceOverとキーボードのために、同じ操作を「先頭へ移動」「前へ移動」「後ろへ移動」「末尾へ移動」として、セルのカスタムアクションと長押しのメニューにも置く。
/// 同じ場所に、添付を外す「削除」も置く。
@MainActor
final class ComposeAttachmentStrip: UIView {
    /// サムネイルの一辺。
    static let itemSize: CGFloat = 64
    /// サムネイルを読み込む大きさ。iPhoneの画面の倍率の最大（3倍）に合わせる。
    static let thumbnailPixelSize = itemSize * 3

    /// 編集している投稿に付いている添付のサムネイル。枠が64ptと小さいので、元の画像は読まず、サーバーのプレビュー画像を少し引き伸ばして出す。
    /// 書いていないときのカプセルのサムネイルも、同じ決め方で読む。
    static let attachedThumbnailPolicy = MediaThumbnailPolicy(enhancement: nil, upscaleTolerance: 2)

    /// サムネイルを押したときに呼ぶ。
    var onSelect: (DraftAttachment.ID) -> Void = { _ in }
    /// 並べ替えたときに、移した添付と移した先の位置を渡して呼ぶ。
    var onMove: (DraftAttachment.ID, Int) -> Void = { _, _ in }
    /// 削除を選んだときに、外す添付を渡して呼ぶ。
    var onRemove: (DraftAttachment.ID) -> Void = { _ in }
    /// 長押しのメニューを出す直前と、閉じ始めたときに呼ぶ。メニューの間、iOSはソフトウェアキーボードを隠す。
    var onContextMenuWillShow: () -> Void = {}
    var onContextMenuWillEnd: () -> Void = {}

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, DraftAttachment.ID>?
    private var items: [DraftAttachment.ID: Item] = [:]
    /// 投稿を送っている間と、準備を待っている間。並べ替え、移動、削除を受け付けない。送る中身は押した時点で決めるため。
    private var isLocked = false

    struct Item {
        let attachment: DraftAttachment
        let local: LocalMedia<UIImage>?
        let status: ComposeAttachmentStatus
        /// 送っている間の進み具合。0から1。送っていなければnil。
        var progress: Double? = nil
        /// 閲覧注意にして投稿する。どの添付も同じ値になる。
        let isSensitive: Bool

        /// サーバーのメディアで描く添付の、サーバーの添付ファイル。編集している投稿に付いている添付と、予約から戻した添付のように、端末にファイルがないもの。手元で選んだ添付ではnil。
        var attachedMedia: MediaAttachment? {
            guard attachment.isAttachedToStatus || local?.file == nil, case .uploaded(let media) = attachment.state else { return nil }
            return media
        }
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
            cell.configure(item, actions: self.actions(for: id, at: indexPath.item))
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, DraftAttachment.ID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        // ドロップしたら、データソースが並びを当て直してから知らせてくる。
        dataSource.reorderingHandlers.canReorderItem = { [weak self] _ in !(self?.isLocked ?? true) }
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
    /// - Parameter isLocked: 投稿を送っている間と、準備を待っている間。
    func update(_ newItems: [Item], isLocked: Bool = false) {
        self.isLocked = isLocked
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

    /// 添付のサムネイルに重ねた、状態の表示（暗い下地、進み具合、失敗のアイコン、閲覧注意のバッジ）。
    func overlay(for id: DraftAttachment.ID) -> UIView? {
        guard window != nil, !isHidden, let indexPath = dataSource?.indexPath(for: id),
              let cell = collectionView.cellForItem(at: indexPath) as? ComposeAttachmentCell
        else { return nil }
        return cell.overlay
    }

    /// 添付を見える位置までスクロールする。ビューアを閉じるとき、戻り先のサムネイルが列の外にあると、画像を薄くして消すしかないため。
    func scrollToItem(_ id: DraftAttachment.ID) {
        guard let indexPath = dataSource?.indexPath(for: id) else { return }
        collectionView.scrollToItem(at: indexPath, at: [], animated: false)
    }

    private var itemCount: Int {
        dataSource?.snapshot().numberOfItems ?? 0
    }

    /// 移動と削除の操作。端にあって動かせない向きは含めない。
    /// 先頭へ・末尾へは、前へ・後ろへと同じ位置に移すとき（隣が端のとき）は出さず、同じ結果の項目を並べない。
    private func actions(for id: DraftAttachment.ID, at index: Int) -> [AttachmentAction] {
        guard !isLocked else { return [] }
        let last = itemCount - 1
        var actions: [AttachmentAction] = []
        if index > 1 {
            actions.append(AttachmentAction(title: "先頭へ移動", systemImage: "arrow.left.to.line") { [weak self] in self?.onMove(id, 0) })
        }
        if index > 0 {
            actions.append(AttachmentAction(title: "前へ移動", systemImage: "arrow.left") { [weak self] in self?.onMove(id, index - 1) })
        }
        if index < last {
            actions.append(AttachmentAction(title: "後ろへ移動", systemImage: "arrow.right") { [weak self] in self?.onMove(id, index + 1) })
        }
        if index < last - 1 {
            actions.append(AttachmentAction(title: "末尾へ移動", systemImage: "arrow.right.to.line") { [weak self] in self?.onMove(id, last) })
        }
        actions.append(AttachmentAction(title: "削除", systemImage: "trash", isDestructive: true) { [weak self] in self?.onRemove(id) })
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

/// 移動と削除の操作。セルのカスタムアクションと長押しのメニューで同じものを出す。
private struct AttachmentAction {
    let title: String
    let systemImage: String
    var isDestructive = false
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
        let actions = actions(for: id, at: indexPath.item)
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            let elements = actions.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.systemImage), attributes: action.isDestructive ? .destructive : []) { _ in action.handler() }
            }
            // 削除は移動と区切って最後に置く。
            let moves = elements.filter { !$0.attributes.contains(.destructive) }
            let removes = elements.filter { $0.attributes.contains(.destructive) }
            return UIMenu(children: [UIMenu(options: .displayInline, children: moves), UIMenu(options: .displayInline, children: removes)])
        })
    }
}

extension ComposeAttachmentStrip: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard !isLocked, let id = dataSource?.itemIdentifier(for: indexPath) else { return [] }
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
    /// 状態の表示を、サムネイルと同じ角の丸い枠に収める。投稿欄の開閉では、サムネイルと一緒に隠し、像を複製に載せて運ぶ。
    let overlay = UIView()
    /// 送信中と変換待ちの間、サムネイルを少し暗くする。
    private let dimView = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// 送っている間の進み具合。満ちたら、サーバーの変換待ちの回る表示に替わる。
    private let progressRing = ProgressRingView()
    private let failureView = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    /// 代替テキストの送信中に、ALTのバッジの位置に出す小さな回る表示。
    private let descriptionSpinner = UIActivityIndicatorView(style: .medium)
    /// 代替テキストを送れなかったときに、ALTのバッジの位置に出すエラーのアイコン。
    private let descriptionFailureView = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    /// 閲覧注意にして投稿するときに、右上に出すバッジ。画像は隠さず、並べ替えや代替テキストを書くときに、どの添付か見分けられるようにする。
    private let sensitiveBadge = ComposeAttachmentCell.makeSensitiveBadge()

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
        for view in [dimView, spinner, progressRing, failureView, descriptionSpinner, descriptionFailureView, sensitiveBadge] {
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
            progressRing.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            progressRing.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            progressRing.widthAnchor.constraint(equalToConstant: 24),
            progressRing.heightAnchor.constraint(equalToConstant: 24),
            failureView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            failureView.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            // ALTのバッジと同じ左下に置く。
            descriptionSpinner.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 2),
            descriptionSpinner.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -2),
            descriptionFailureView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 5),
            descriptionFailureView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -5),
            // ALTやGIFのバッジと同じく、枠から6pt離す。
            sensitiveBadge.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -6),
            sensitiveBadge.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 6),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ item: ComposeAttachmentStrip.Item, actions: [AttachmentAction]) {
        let description = item.attachment.description
        let showsDescriptionState = item.status == .sendingDescription || item.status == .descriptionFailed
        // 代替テキストの送信中と失敗は、バッジの位置（左下）に状態を出すため、バッジを出さない。
        tile.hidesBadge = showsDescriptionState
        if let attached = item.attachedMedia {
            // 編集している投稿に付いている添付は、手元にファイルがないので、サーバーのプレビュー画像を描く。ALTのバッジは書き換えた代替テキストで決める。
            tile.apply(attached.replacingDescription(description), hiddenCount: 0, isCovered: false, policy: ComposeAttachmentStrip.attachedThumbnailPolicy)
        } else {
            tile.applyLocal(thumbnail: item.local?.thumbnail, kind: item.local?.displayKind, description: showsDescriptionState ? "" : description)
        }
        // 送っている間は進み具合の円を満たし、満ちたらサーバーの変換待ちの回る表示に替える。変換にかかる時間は分からない。
        let isWorking = item.status == .exporting || item.status == .uploading || item.status == .processing
        dimView.isHidden = !isWorking
        progressRing.isHidden = item.progress == nil
        progressRing.progress = item.progress ?? 0
        setAnimating(spinner, item.status == .processing)
        failureView.isHidden = item.status != .failed
        setAnimating(descriptionSpinner, item.status == .sendingDescription)
        descriptionFailureView.isHidden = item.status != .descriptionFailed
        sensitiveBadge.isHidden = !item.isSensitive
        let kindName = (item.local?.displayKind ?? item.attachedMedia?.type).map(MediaTileView.kindName(of:)) ?? "メディア"
        accessibilityLabel = [kindName, item.isSensitive ? "閲覧注意" : "", description].filter { !$0.isEmpty }.joined(separator: "、")
        accessibilityValue = switch item.status {
        case .exporting: ["書き出し中", item.progress.flatMap(Notice.percentText(of:))].compactMap(\.self).joined(separator: "、")
        case .uploading: ["アップロード中", item.progress.flatMap(Notice.percentText(of:))].compactMap(\.self).joined(separator: "、")
        case .processing: "サーバーで処理中"
        case .ready: nil
        case .sendingDescription: "代替テキストを送信中"
        case .failed: "アップロードできませんでした"
        case .descriptionFailed: "代替テキストを送信できませんでした"
        }
        accessibilityTraits = .button
        accessibilityHint = "開いて代替テキストを編集できます。"
        accessibilityCustomActions = actions.map { action in
            UIAccessibilityCustomAction(name: action.title) { _ in
                action.handler()
                return true
            }
        }
    }

    /// ALTのバッジと同じ黒い下地に、タイムラインの閲覧注意のぼかしと同じアイコンを描く。
    private static func makeSensitiveBadge() -> UIView {
        let image = UIImageView(image: UIImage(systemName: "eye.slash"))
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small).applying(UIImage.SymbolConfiguration(weight: .bold))
        image.tintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        let badge = UIView()
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        badge.layer.cornerRadius = 4
        badge.layer.cornerCurve = .continuous
        badge.isHidden = true
        badge.addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 4),
            image.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -4),
            image.topAnchor.constraint(equalTo: badge.topAnchor, constant: 3),
            image.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -3),
        ])
        return badge
    }

    private func setAnimating(_ spinner: UIActivityIndicatorView, _ animating: Bool) {
        if animating {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }
}

/// 進み具合の円。下地の円の上に、割合の分だけ時計回りに弧を描く。
private final class ProgressRingView: UIView {
    var progress: Double = 0 {
        didSet { progressLayer.strokeEnd = min(max(progress, 0), 1) }
    }

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for layer in [trackLayer, progressLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 3
            self.layer.addSublayer(layer)
        }
        trackLayer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        progressLayer.strokeColor = UIColor.white.cgColor
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = trackLayer.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // 上から時計回りに満たす。
        let path = UIBezierPath(arcCenter: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        for layer in [trackLayer, progressLayer] {
            layer.frame = bounds
            layer.path = path.cgPath
        }
    }
}
