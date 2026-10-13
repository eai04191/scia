import UIKit

/// タイムライン末尾の、古い投稿の読み込み状態を出すフッター。
final class TimelineFooterView: UICollectionReusableView {
    var onRetry: (() -> Void)?

    private let indicator = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private lazy var retryButton = UIButton(configuration: .plain(), primaryAction: UIAction(title: "再試行") { [weak self] _ in
        self?.onRetry?()
    })
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        [indicator, label, retryButton].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ state: TimelineViewController.FooterState) {
        switch state {
        case .idle:
            indicator.stopAnimating()
            label.text = nil
            retryButton.isHidden = true
        case .loading:
            indicator.startAnimating()
            label.text = nil
            retryButton.isHidden = true
        case .failed(let message):
            indicator.stopAnimating()
            label.text = "読み込めませんでした: \(message)"
            retryButton.isHidden = false
        case .reachedEnd:
            indicator.stopAnimating()
            label.text = "これより前の投稿はありません"
            retryButton.isHidden = true
        }
        label.isHidden = label.text == nil
    }
}
