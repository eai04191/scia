import SciaCore
import UIKit

/// カスタム絵文字の画像を1つ描くビュー。アニメーション版を渡すと、静止画の代わりにコマを送る層を描く。
/// 投稿欄の補完の候補のように、文字の中ではなく、絵文字だけを並べる場所で使う。視差効果を減らす設定では動かさない。
final class EmojiImageView: UIImageView {
    /// 静止画。アニメーション版がないときと、動かさないときに描く。
    var stillImage: UIImage? {
        didSet { update() }
    }

    /// アニメーション版。nilなら静止画を描く。
    var animation: EmojiAnimation? {
        didSet {
            guard animation !== oldValue else { return }
            animatedLayer?.removeFromSuperlayer()
            animatedLayer = nil
            update()
        }
    }

    private var animatedLayer: CALayer?
    private var observers: [any NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFit
        let center = NotificationCenter.default
        // 裏に回っている間に描画のサーバーがアニメーションを外していることがあるため、戻ったら作り直す。視差効果を減らす設定が変わったら、動かすかを決め直す。
        observers = [UIApplication.willEnterForegroundNotification, UIAccessibility.reduceMotionStatusDidChangeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.animatedLayer?.removeFromSuperlayer()
                    self?.animatedLayer = nil
                    self?.update()
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animatedLayer?.frame = bounds
        CATransaction.commit()
    }

    private func update() {
        guard let animation, !UIAccessibility.isReduceMotionEnabled else {
            animatedLayer?.removeFromSuperlayer()
            animatedLayer = nil
            image = stillImage
            return
        }
        // 静止画を残すと、透明な部分から重なって見えるため、動かす間は描かない。
        image = nil
        guard animatedLayer == nil else { return }
        let layer = AnimatedEmojiOverlay.makeLayer(animation.image, scale: traitCollection.displayScale)
        layer.frame = bounds
        self.layer.addSublayer(layer)
        animatedLayer = layer
    }
}
