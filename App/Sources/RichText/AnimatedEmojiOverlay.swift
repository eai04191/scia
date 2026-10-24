import SciaCore
import UIKit

/// `LinkLabel`の文字に埋め込んだカスタム絵文字のうち、アニメーションするものを動かす。
/// UILabelは埋め込んだ画像を動かせないため、文字の中の絵文字は同じ大きさの透明な画像に差し替えて場所だけを取り、
/// その位置に、Core Animationでコマを送る層を重ねる。コマ送りは描画のサーバーが受け持つので、画面の外や裏に回ったラベルでは描かれない。
/// 層には全コマを並べた1枚の画像を1度だけ渡し、表示する範囲（`contentsRect`）だけを切り替えてコマを送る。
/// 同じ長さのアニメーションは、ラベルをまたいでも同じコマを出すよう、時刻で揃えて始める。
/// 視差効果を減らす設定では動かさず、静止画のまま描く。
@MainActor
final class AnimatedEmojiOverlay {
    /// 動かす絵文字。`index`は文字列の中の位置。
    struct Entry {
        let index: Int
        /// 層が使っている間、同じインスタンスを返せるよう、参照ごと持つ。
        let animation: EmojiAnimation
        /// 動く層の上に重ねる色。編集履歴で足した絵文字を示す。
        let tint: UIColor?

        /// 同じ位置に同じアニメーションを同じ色で描く。
        func isSame(as other: Entry) -> Bool {
            index == other.index && animation === other.animation && tint == other.tint
        }
    }

    private let store: EmojiImageStore
    /// アニメーション版が届いたときと、設定が変わったときに、文字を差し替え直す。
    private let onChange: @MainActor () -> Void
    /// 今の文字列にある絵文字の、元の画像のURL。届いたアニメーションがこのラベルのものかを見分ける。
    private var emojiURLs: Set<URL> = []
    private(set) var entries: [Entry] = []
    private var layers: [CALayer] = []
    /// 層を作ったときの`entries`。変わっていなければ、層を作り直さずに位置だけを合わせる。
    private var layersGeneration = 0
    private var entriesGeneration = 0
    private var observers: [any NSObjectProtocol] = []

    init(store: EmojiImageStore, onChange: @escaping @MainActor () -> Void) {
        self.store = store
        self.onChange = onChange
        store.addListener(owner: self) { [weak self] urls in
            guard let self, !urls.isDisjoint(with: emojiURLs) else { return }
            self.onChange()
        }
        let center = NotificationCenter.default
        observers = [UIAccessibility.reduceMotionStatusDidChangeNotification, UIApplication.willEnterForegroundNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // 裏から戻ったときは、裏に回っている間に描画のサーバーがアニメーションを外していることがあるため、層を外して作り直させる。
                    // 同じ絵文字なら層を使い続けるので、外しておかないと作り直されない。
                    if name == UIApplication.willEnterForegroundNotification {
                        self?.removeLayers()
                    }
                    // 視差効果を減らす設定が変わったときは、動かすかどうかを決め直す。
                    self?.onChange()
                }
            }
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// `text`の、アニメーション版が届いている絵文字を透明な画像に差し替えた文字列。差し替えるものがなければ`text`をそのまま返す。
    /// まだ届いていない絵文字は読み込みを始め、届いたら`onChange`を呼ぶ。
    /// - Parameter stillIndices: 動かさず、文字の中の静止画のまま描く絵文字の位置。
    func prepare(_ text: NSAttributedString?, keepingStill stillIndices: Set<Int> = []) -> NSAttributedString? {
        // 組み終えるまで前の`entries`を持っておく。先に手放すと、置き場から捨てられたアニメーションの最後の参照が切れ、読み直すことになるため。
        var entries: [Entry] = []
        defer {
            // セルを描き直すたびに層を作り直さないよう、同じ絵文字を同じ位置に描くなら今の層を使い続ける。
            if entries.count != self.entries.count || !zip(entries, self.entries).allSatisfy({ $0.isSame(as: $1) }) {
                entriesGeneration += 1
            }
            self.entries = entries
        }
        emojiURLs = []
        guard let text, text.length > 0, !UIAccessibility.isReduceMotionEnabled else { return text }
        var result: NSMutableAttributedString?
        text.enumerateAttribute(.customEmoji, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let emoji = value as? CustomEmoji else { return }
            emojiURLs.insert(emoji.url)
            guard let animation = store.animation(for: emoji.url) else { return }
            // 同じ絵文字が続くと1つの範囲にまとまるため、1文字ずつ差し替える。
            for index in range.location..<NSMaxRange(range) where !stillIndices.contains(index) {
                guard let attachment = text.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment else { continue }
                let placeholder = NSTextAttachment()
                placeholder.image = Self.clearImage
                placeholder.bounds = attachment.bounds
                let mutable = result ?? NSMutableAttributedString(attributedString: text)
                mutable.addAttribute(.attachment, value: placeholder, range: NSRange(location: index, length: 1))
                result = mutable
                entries.append(Entry(index: index, animation: animation, tint: text.attribute(.emojiTint, at: index, effectiveRange: nil) as? UIColor))
            }
        }
        return result ?? text
    }

    /// `entries`の絵文字を、`frames`（`entries`と同じ順の、ラベルの座標の枠）に重ねる。枠がnilの絵文字は出さない。
    func layout(in host: CALayer, frames: [CGRect?]) {
        if layersGeneration != entriesGeneration {
            rebuildLayers(in: host)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, frame) in zip(layers, frames) {
            if let frame {
                layer.frame = frame
                layer.sublayers?.forEach { tint in
                    tint.frame = layer.bounds
                    tint.mask?.frame = tint.bounds
                }
                layer.isHidden = false
            } else {
                layer.isHidden = true
            }
        }
        CATransaction.commit()
    }

    /// 層を外す。次の`layout`で作り直す。
    func removeLayers() {
        layers.forEach { $0.removeFromSuperlayer() }
        layers = []
        layersGeneration = -1
    }

    private func rebuildLayers(in host: CALayer) {
        removeLayers()
        let scale = host.contentsScale
        layers = entries.map { entry in
            let layer = Self.makeLayer(entry.animation.image, scale: scale)
            if let tint = entry.tint {
                let tintLayer = CALayer()
                // 層はラベルを並べる途中で作るので、`current`はラベルの見た目の設定になる。作ったあとにライトとダークを切り替えても、同じ絵文字なら層を使い続けるため色は前のままになるが、
                // 足した部分の緑は両方でほぼ同じ色なので、そのために作り直さない。
                tintLayer.backgroundColor = tint.resolvedColor(with: UITraitCollection.current).cgColor
                // 絵文字の描かれている画素にだけ重ねる。透明な部分にも重ねると、ラベルが塗った下地と重なって、そこだけ色が濃くなるため。
                // マスクも同じ時刻で始めるので、絵文字と同じコマを送る。
                tintLayer.mask = Self.makeLayer(entry.animation.image, scale: scale)
                layer.addSublayer(tintLayer)
            }
            host.addSublayer(layer)
            return layer
        }
        layersGeneration = entriesGeneration
    }

    /// `image`のコマを送る層。枠いっぱいに、縦横比を保って描く。
    static func makeLayer(_ image: AnimatedImage, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = scale
        layer.contents = image.sheet
        layer.contentsRect = image.contentsRect(ofFrame: 0)
        layer.add(frameAnimation(of: image), forKey: "frames")
        return layer
    }

    /// コマを送るアニメーション。並べた画像の中の、表示する範囲を切り替える。
    /// 始める位置を今の時刻を1周の長さで割った余りにして、同じ長さのアニメーションを揃える。
    /// - Parameter mediaTime: 画面の描き換えと同じ時間の、今の時刻。
    static func frameAnimation(of image: AnimatedImage, mediaTime: CFTimeInterval = AppDependencies.mediaTime()) -> CAKeyframeAnimation {
        let total = image.duration
        var keyTimes: [NSNumber] = [0]
        var elapsed = 0.0
        for duration in image.durations {
            elapsed += duration
            keyTimes.append(NSNumber(value: elapsed / total))
        }
        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.values = (0..<image.frameCount).map { NSValue(cgRect: image.contentsRect(ofFrame: $0)) }
        // 区切りごとに切り替える送り方では、時刻の数をコマの数より1つ多くし、最後を1にする。
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timeOffset = mediaTime.truncatingRemainder(dividingBy: total)
        return animation
    }

    private static let clearImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
}
