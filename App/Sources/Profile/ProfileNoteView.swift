import UIKit

/// プロフィールの自己紹介。切っているときは、App Storeの説明文のように、最後の行の右端に「さらに表示」を重ね、その手前の文字を透明へ向けてぼかす。
/// ぼかしはラベルの層のマスクでかけるので、後ろのヘッダー画像の映り込みが透けても、重ねた動くカスタム絵文字の層も一緒にぼける。
final class ProfileNoteView: UIView {
    /// 「さらに表示」の手前で、文字をぼかす幅。
    var fadeWidth: CGFloat = 32 {
        didSet {
            guard fadeWidth != oldValue else { return }
            setNeedsLayout()
        }
    }

    private let label: UILabel
    private let button: UIButton
    private let fadeMask = CALayer()
    private let maskAbove = CALayer()
    private let maskFade = CAGradientLayer()

    init(label: UILabel, button: UIButton) {
        self.label = label
        self.button = button
        super.init(frame: .zero)
        maskAbove.backgroundColor = UIColor.black.cgColor
        maskFade.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        maskFade.startPoint = CGPoint(x: 0, y: 0.5)
        maskFade.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.addSublayer(maskAbove)
        fadeMask.addSublayer(maskFade)

        label.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(button)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 最後に見えている行に、文字の並びを揃えて重ねる。
            button.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            button.lastBaselineAnchor.constraint(equalTo: label.lastBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFade()
    }

    /// 「さらに表示」を出している間だけ、その行の手前をぼかす。
    private func updateFade() {
        guard !button.isHidden, label.bounds.width > 0 else {
            label.layer.mask = nil
            return
        }
        let buttonFrame = convert(button.frame, to: label)
        let bounds = label.bounds
        let fadeEnd = max(buttonFrame.minX, 0)
        let fadeStart = max(fadeEnd - fadeWidth, 0)
        CATransaction.begin()
        // 広げたり別のアカウントを出したりしたときに、マスクが前の位置から動いて見えないようにする。
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        maskAbove.frame = CGRect(x: 0, y: 0, width: bounds.width, height: buttonFrame.minY)
        maskFade.frame = CGRect(x: 0, y: buttonFrame.minY, width: bounds.width, height: bounds.height - buttonFrame.minY)
        maskFade.locations = [NSNumber(value: fadeStart / bounds.width), NSNumber(value: fadeEnd / bounds.width)]
        CATransaction.commit()
        label.layer.mask = fadeMask
    }
}
