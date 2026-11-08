import SciaCore
import UIKit

/// タイムラインの行。スクロールの間に、行の大きさを測るのにかかった時間を、行の種類ごとに`FrameWork`へ渡す。
/// 行の大きさは、中身のビューではなくセルが測られるため、セルで測る。
final class TimelineCell: UICollectionViewListCell, SizingMeasurable {
    /// 行の高さを測るときに、スタックに残す行の種類と部品。測った時間に付ける名前にも使う。
    var sizingTrace = SizingTrace()
    /// 出している行。別の行を出し始めたかを見分ける。
    var itemID: TimelineViewController.ItemID?

    /// 縮む途中に重ねている、縮む前の像。アクションバーを閉じるときに使う（`TimelineViewController.concealShrink`）。
    private var shrinkSnapshot: UIView?

    /// 縮む前の像を重ねているか。テストで、閉じる動きを見るのに使う。
    var isShowingShrinkSnapshot: Bool {
        shrinkSnapshot != nil
    }

    /// 縮む前の像を重ねる。前に重ねていた像は外す。
    func showShrinkSnapshot(_ snapshot: UIView) {
        shrinkSnapshot?.removeFromSuperview()
        shrinkSnapshot = snapshot
        addSubview(snapshot)
    }

    /// 縮み終えたら像を外す。途中で別の像に替わっていたら、そちらは外さない。
    func removeShrinkSnapshot(_ snapshot: UIView) {
        guard shrinkSnapshot === snapshot else { return }
        snapshot.removeFromSuperview()
        shrinkSnapshot = nil
    }

    /// 縮む途中に中身を入れ直したら、像を外す。像は縮む前の中身なので、残すと新しい中身の手前に古い中身が見える。
    /// 縮む動きの途中で外れるので、まわりのアイテムがまだ動いていても、アクションバーはそのコマで消える。
    func discardShrinkSnapshot() {
        shrinkSnapshot?.removeFromSuperview()
        shrinkSnapshot = nil
    }

    /// 縮む途中に別の投稿に使い回されたら、前の投稿の像を残さない。
    override func prepareForReuse() {
        super.prepareForReuse()
        discardShrinkSnapshot()
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        FrameWork.measure("\(sizingTrace.row.rawValue).sizing") { sizingTrace.run(on: self, layoutAttributes) }
    }

    func measureSizing(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        super.preferredLayoutAttributesFitting(attributes)
    }

    /// 高さを測るときにスタックに残す部品を、今の中身に合わせる。
    func updateSizingParts(from configuration: (any UIContentConfiguration)?) {
        sizingTrace.parts = (configuration as? any SizingTraceable)?.sizingParts ?? []
    }

    /// まとめて行う操作のために投稿を選んでいる間に、行の右上に出す丸。決まりはdocs/batch-actions.mdの「選んでいる間」にある。
    enum SelectionMark: Equatable {
        case unselected
        /// 選んだ順の番号。1から数える。
        case selected(Int)
    }

    private var selectionMarkView: SelectionMarkView?
    private var selectionTintView: UIView?

    /// 丸を出し、選んだ行の背景に薄く色を付ける。nilなら外す。
    /// 丸を出している間は、行の中の部品（本文のリンク、添付ファイル、アイコンなど）に触れたものを届けず、行のタップで選ぶか外すかだけにする。
    func setSelectionMark(_ mark: SelectionMark?) {
        contentView.isUserInteractionEnabled = mark == nil
        guard let mark else {
            selectionMarkView?.isHidden = true
            selectionTintView?.isHidden = true
            return
        }
        let markView = selectionMarkView ?? makeSelectionMarkView()
        let tintView = selectionTintView ?? makeSelectionTintView()
        markView.isHidden = false
        markView.mark = mark
        bringSubviewToFront(markView)
        tintView.isHidden = mark == .unselected
    }

    private func makeSelectionMarkView() -> SelectionMarkView {
        let view = SelectionMarkView()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
        selectionMarkView = view
        return view
    }

    private func makeSelectionTintView() -> UIView {
        let view = UIView()
        view.backgroundColor = .tintColor.withAlphaComponent(0.1)
        view.isUserInteractionEnabled = false
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(view, belowSubview: contentView)
        selectionTintView = view
        return view
    }
}

/// 選んでいる間の行の丸。選んでいない行は白い丸のフチだけ、選んだ行はアクセントカラーの丸に番号を出す。写真のピッカーで順番を付けて選ぶときと同じ見せ方にする。
private final class SelectionMarkView: UIView {
    private static let side: CGFloat = 24
    private let label = UILabel()

    var mark: TimelineCell.SelectionMark = .unselected {
        didSet { apply() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = Self.side / 2
        layer.borderWidth = 1.5
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .white
        // 丸の大きさは決まっているので、文字を大きくする設定や3桁の番号では、丸に収まるまで縮める。
        let font = UIFont.monospacedDigitFont(forTextStyle: .footnote)
        label.font = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.4
        label.baselineAdjustment = .alignCenters
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SelectionMarkView, _) in view.apply() }
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func apply() {
        switch mark {
        case .unselected:
            backgroundColor = UIColor.black.withAlphaComponent(0.15)
            layer.borderColor = UIColor.white.cgColor
            label.text = nil
        case .selected(let number):
            backgroundColor = .tintColor
            layer.borderColor = UIColor.white.cgColor
            label.text = "\(number)"
        }
    }
}

extension TimelineEntry {
    /// `FrameWork`で測った時間に付ける名前と、高さを測るときにスタックに残す名前に使う、行の種類。
    var rowKind: TimelineRowKind {
        switch self {
        case .status: .status
        case .pinned: .pinned
        case .gap: .gap
        case .notification: .notification
        case .unreadable: .unreadable
        case .account: .account
        case .notificationRequest: .notificationRequest
        case .search: .search
        }
    }
}
