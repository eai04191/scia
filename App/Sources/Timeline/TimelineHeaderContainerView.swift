import UIKit

/// 一覧の頭に、外から渡されたビューを1つ置く入れ物。中のビューの制約で高さが決まる。
final class TimelineHeaderContainerView: UICollectionReusableView {
    private weak var hosted: UIView?

    func host(_ view: UIView?) {
        guard view !== hosted || view?.superview !== self else { return }
        // 同じビューが別の入れ物へ移っていれば、そちらから外さない。
        if let hosted, hosted.superview === self {
            hosted.removeFromSuperview()
        }
        hosted = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 一覧はこの入れ物を測るため、載せたビューが幅に合わせて中身を決め直す測り方（`systemLayoutSizeFitting`の上書き）を持っていても、そのままでは呼ばれない。
    /// 入れ物は載せたビューの四辺に合わせているだけなので、測るのは載せたビューに任せる。
    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        guard let hosted, hosted.superview === self else {
            return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
        }
        return hosted.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }

    /// 載せたビューが枠の外にはみ出して描いている部分（ナビゲーションバーの下まで上げたヘッダー画像）も、タップを受ける。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let hosted, hosted.superview === self else { return super.point(inside: point, with: event) }
        return super.point(inside: point, with: event) || hosted.point(inside: convert(point, to: hosted), with: event)
    }
}
