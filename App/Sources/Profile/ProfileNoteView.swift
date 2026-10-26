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
    /// 広げる途中で、切っていた行より下に増えた行を見せる部分。
    private let maskBelow = CALayer()
    /// 広げる動きの途中。ぼかしを消し終えるまで、マスクを広げる前の行の位置に残す。
    private(set) var isExpanding = false
    /// 動きの途中で切り直したときに、古い動きの終わりで片付けないための番号。
    private var expansionID = 0

    init(label: UILabel, button: UIButton) {
        self.label = label
        self.button = button
        super.init(frame: .zero)
        maskAbove.backgroundColor = UIColor.black.cgColor
        maskBelow.backgroundColor = UIColor.black.cgColor
        maskFade.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        maskFade.startPoint = CGPoint(x: 0, y: 0.5)
        maskFade.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.addSublayer(maskAbove)
        fadeMask.addSublayer(maskFade)
        fadeMask.addSublayer(maskBelow)

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

    /// 切っていた自己紹介を、全文に広げる。ラベルはすでに全文を描く行数にしてある前提。
    /// `duration`が0より大きければ、広がる枠で増えた行を上から見せていき、そのあいだに「さらに表示」の手前のぼかしを消していく。
    /// 枠を広げるのは、同じ長さの動きの中で並べ直す呼び出し元に任せる。
    /// 「さらに表示」はすぐ消す。ラベルの最後の行に揃えて重ねているため、残すと広げた最後の行へ動いて見えるため。
    func expand(duration: TimeInterval) {
        let isFading = !button.isHidden && label.layer.mask != nil
        button.isHidden = true
        guard duration > 0, isFading else {
            setNeedsLayout()
            return
        }
        expansionID += 1
        let id = expansionID
        isExpanding = true
        // 枠より下へ全文を描いておき、広がる枠で切って見せる。描いた文字を枠の大きさに引き伸ばさないよう、上に寄せる。
        clipsToBounds = true
        label.contentMode = .top
        let width = label.bounds.width
        let fullHeight = label.textRect(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude), limitedToNumberOfLines: 0).height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = CGRect(x: 0, y: 0, width: width, height: max(fullHeight, maskFade.frame.maxY))
        maskBelow.frame = CGRect(x: 0, y: maskFade.frame.maxY, width: width, height: max(fullHeight - maskFade.frame.maxY, 0))
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, expansionID == id else { return }
            finishExpanding()
        }
        maskFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor]
        CATransaction.commit()
    }

    /// 広げる動きを止めて、マスクと描き方を元に戻す。動きの途中で別のアカウントを出したときにも呼ぶ。
    func finishExpanding() {
        guard isExpanding else { return }
        expansionID += 1
        isExpanding = false
        clipsToBounds = false
        label.contentMode = .redraw
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskFade.removeAllAnimations()
        maskFade.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        maskBelow.frame = .zero
        CATransaction.commit()
        setNeedsLayout()
    }

    /// 「さらに表示」を出している間だけ、その行の手前をぼかす。
    private func updateFade() {
        // 広げる途中は、マスクを広げる前の行の位置に残し、ぼかしを消していく。
        guard !isExpanding else { return }
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
