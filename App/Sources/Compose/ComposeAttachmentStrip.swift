import SciaCore
import UIKit

/// 投稿欄の入力欄の上に、添付したメディアを同じ大きさの正方形のサムネイルで横一列に並べる。
/// 上限が4枚より多いサーバーでも1段のまま並べ、収まらない分は横にスクロールする。
@MainActor
final class ComposeAttachmentStrip: UIView {
    /// サムネイルの一辺。
    static let itemSize: CGFloat = 64
    /// サムネイルを読み込む大きさ。iPhoneの画面の倍率の最大（3倍）に合わせる。
    static let thumbnailPixelSize = itemSize * 3

    /// サムネイルを押したときに呼ぶ。
    var onSelect: (DraftAttachment.ID) -> Void = { _ in }

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, DraftAttachment.ID>?
    private var items: [DraftAttachment.ID: Item] = [:]

    struct Item {
        let attachment: DraftAttachment
        let local: LocalMedia?
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
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: Self.itemSize),
        ])
        let registration = UICollectionView.CellRegistration<ComposeAttachmentCell, DraftAttachment.ID> { [weak self] cell, _, id in
            guard let item = self?.items[id] else { return }
            cell.configure(item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 並びと各サムネイルの状態を描き直す。足したものは後ろに付け、並びの変わらないものは中身だけ描き直す。
    func update(attachments: [DraftAttachment], localMedia: [DraftAttachment.ID: LocalMedia]) {
        items = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, Item(attachment: $0, local: localMedia[$0.id])) })
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, DraftAttachment.ID>()
        snapshot.appendSections([0])
        snapshot.appendItems(attachments.map(\.id))
        snapshot.reconfigureItems(attachments.map(\.id).filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: window != nil)
    }
}

extension ComposeAttachmentStrip: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
        onSelect(id)
    }
}

/// 添付したメディア1つのサムネイル。アップロードの進み具合と失敗を重ねて見せる。
private final class ComposeAttachmentCell: UICollectionViewCell {
    private let imageView = UIImageView()
    /// 送信中と変換待ちの間、サムネイルを少し暗くする。
    private let dimView = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureView = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    private let kindBadge = MediaTileView.makeBadge("")

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        contentView.layer.cornerRadius = MediaGridView.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        spinner.color = .white
        // 感嘆符を白、円を赤で描き、どんなサムネイルの上でも見分けられるようにする。
        failureView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        for view in [imageView, dimView, spinner, failureView, kindBadge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: contentView.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failureView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            failureView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            kindBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            kindBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ item: ComposeAttachmentStrip.Item) {
        imageView.image = item.local?.thumbnail
        let kind = item.local?.file?.kind
        kindBadge.text = switch kind {
        case .gifv: "GIF"
        case .video: "動画"
        default: nil
        }
        kindBadge.isHidden = kindBadge.text == nil
        // 送信の進み具合はまだ受け取っていないので、送信中も変換待ちと同じ回る表示にする。
        let isWorking: Bool
        let isFailed: Bool
        switch item.attachment.state {
        case .uploading, .processing: (isWorking, isFailed) = (true, false)
        case .uploaded: (isWorking, isFailed) = (false, false)
        case .failed: (isWorking, isFailed) = (false, true)
        }
        dimView.isHidden = !isWorking
        if isWorking {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        failureView.isHidden = !isFailed
        // 読み込む前は種類が分からないので「メディア」にする。
        accessibilityLabel = "\(kind == .image ? "画像" : kindBadge.text ?? "メディア")の添付"
        accessibilityValue = switch item.attachment.state {
        case .uploading: "アップロード中"
        case .processing: "サーバーで処理中"
        case .uploaded: nil
        case .failed: "アップロードできませんでした"
        }
        accessibilityTraits = isFailed ? .button : .image
    }
}
