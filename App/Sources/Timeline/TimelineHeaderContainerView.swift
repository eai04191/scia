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
}
