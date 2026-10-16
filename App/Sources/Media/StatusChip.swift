import UIKit

/// 操作が済んだことを、操作した場所の近くで短く知らせる小さな表示。
///
/// UIKitに同じ役割の部品がないため自前で描く。触れても下の操作を妨げないよう、タッチを受けない。
/// 目で見えない人にも届くよう、出すときにVoiceOverで読み上げる。
final class StatusChip: UIView {
    private let effectView = UIVisualEffectView(effect: UIGlassEffect())
    private let iconView = UIImageView()
    private let label = UILabel()
    private var hideTask: Task<Void, Never>?

    /// 出している文言。出していなければnil。
    private(set) var shownText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        effectView.cornerConfiguration = .capsule()
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        iconView.tintColor = .label
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(stack)
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `duration`秒見せてから消す。消えている途中や見せている途中に呼ばれたら、その場から見せ直し、見せる時間を数え直す。
    func show(_ text: String, systemImage: String, duration: TimeInterval) {
        label.text = text
        iconView.image = UIImage(systemName: systemImage)
        shownText = text
        hideTask?.cancel()
        // 視差効果を減らす設定では、大きさを変えずに薄くするだけにする。
        if alpha == 0, !UIAccessibility.isReduceMotionEnabled {
            transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        }
        UIAccessibility.post(notification: .announcement, argument: text)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.shownText = nil
            // 消えるときも、ゆっくり始めず、出るときより重くならない時間で消す。
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.alpha = 0
            }
        }
    }
}
