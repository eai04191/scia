import UIKit

/// 動画の再生位置を示し、指で動かして位置を変えるバー。
///
/// 標準の再生画面と同じく、つまみを出さず、バーのどこを触ってもその位置へ動かせるようにする。`UISlider`はつまみを消すとつかめなくなるため、自前で描く。
/// 触れた位置の割合を`value`にして、触れたとき`.touchDown`、動かしている間`.valueChanged`、離したとき`.touchUpInside`か`.touchUpOutside`を送る。
/// 動かしている間は、指の下で見えるようバーを太くする。VoiceOverでは、上下に払って1割ずつ動かす。
final class ScrubBar: UIControl {
    /// 長さのうち再生した割合。0から1。
    var value: Double = 0 {
        didSet { setNeedsLayout() }
    }

    private let track = UIView()
    private let fill = UIView()
    private static let thickness: CGFloat = 7
    private static let trackingThickness: CGFloat = 12
    /// 指で動かしている。`isTracking`は`beginTracking`の中でまだ変わっていないことがあるため、太さはこれで決める。
    private var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.isUserInteractionEnabled = false
        fill.isUserInteractionEnabled = false
        track.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        fill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        track.clipsToBounds = true
        track.addSubview(fill)
        addSubview(track)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 細いバーでも指で触れやすいよう、見た目より高くして触れる範囲を広げる。
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 30)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let thickness = isDragging ? Self.trackingThickness : Self.thickness
        track.frame = CGRect(x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
        track.layer.cornerRadius = thickness / 2
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * min(max(value, 0), 1), height: thickness)
    }

    /// 触れた時点では位置を変えるだけで知らせない。`UIControl`は、この後に`.touchDown`を送るため、動かし始めた知らせより先に変更の知らせが届かないようにする。
    /// 触れて動かさずに離したときは、離したときの知らせで、触れた位置へ移る。
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        value = fraction(at: touch)
        isDragging = true
        animateThickness()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        move(to: touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        isDragging = false
        animateThickness()
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        isDragging = false
        animateThickness()
    }

    /// バーの上から始めた横のドラッグを、ページの切り替えや閉じる操作に取られないようにする。`UISlider`がつまみの上でしていることを、バー全体でする。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer.view !== self, gestureRecognizer is UIPanGestureRecognizer {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func accessibilityIncrement() {
        step(by: 0.1)
    }

    override func accessibilityDecrement() {
        step(by: -0.1)
    }

    private func step(by delta: Double) {
        value = min(max(value + delta, 0), 1)
        sendActions(for: .valueChanged)
    }

    private func move(to touch: UITouch) {
        value = fraction(at: touch)
        sendActions(for: .valueChanged)
    }

    private func fraction(at touch: UITouch) -> Double {
        guard bounds.width > 0 else { return value }
        return min(max(Double(touch.location(in: self).x / bounds.width), 0), 1)
    }

    private func animateThickness() {
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }
}
