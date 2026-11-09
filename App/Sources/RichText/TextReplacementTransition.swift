import TextKit2Label
import UIKit

/// 本文を別の文章（原文と訳文）へ置き換えるときの動き。
///
/// 翻訳の単位（段落）ごとに、先頭の語から順に、前の文字を薄くし、そこへ新しい文字を少し下から浮かび上がらせる。
/// 語ごとに少しずつ遅らせ、1行を横切る時間の一部（`fadeWidth`）で濃さを変え、スプリングの移動と合わせる（WWDC24「Create custom visual effects with SwiftUI」の文字の出現と同じ組み立て。ブラーは`CALayer`に公開の手段がないので使わない）。
/// 前の文字と新しい文字の描画を語ごとに切り出す。動かしている間は、ラベル自身の描画と動く絵文字の層を隠す。
/// まだ順番が来ていない段落の前の文字は、新しい位置へ`rowSpring`で動かす。
@MainActor
final class TextReplacementTransition {
    /// 1行の枠と、その行の語ごとの枠。ラベルの座標。
    struct Line: Equatable {
        var rect: CGRect
        var words: [CGRect]
    }

    /// 同じ順番で消して出す、前の行と新しい行の組。
    struct Slot: Equatable {
        var unit: Int
        var old: Line?
        var new: Line?
        /// 前の行を動かす先の上端。
        var oldTargetY: CGFloat
        var start: TimeInterval
        var duration: TimeInterval
    }

    /// 新しい文字が浮かび上がる距離の、行の高さに対する割合。
    private static let riseRatio: CGFloat = 0.3
    /// 新しい本文の高さに入らない行が薄くなる時間の、高さを動かす時間に対する割合。
    private static let extraLineFadeRatio = 0.5

    private let oldText: NSAttributedString
    private let oldImage: CGImage
    private let oldFrames: [Int: CGRect]
    private let oldBars: [CGRect]
    private let duration: TimeInterval
    private let shiftDuration: TimeInterval
    private let wordDuration: TimeInterval
    private let fadeWidth: Double
    private weak var label: EmojiLabel?
    private var overlay: CALayer?
    private var hiddenLayers: [CALayer] = []

    /// 文字列を入れ替える前に呼ぶ。今の描画を残せなければnil。
    /// - Parameter currentImage: 動いている途中から始めるときの、いま見えている描画。
    init?(label: EmojiLabel, text: NSAttributedString, currentImage: CGImage?, duration: TimeInterval, shiftDuration: TimeInterval, wordDuration: TimeInterval, fadeWidth: Double) {
        guard let image = currentImage ?? Self.render(label) else { return nil }
        self.label = label
        oldText = text
        oldImage = image
        oldFrames = EmojiArrivalTransition.characterFrames(of: text, in: label)
        oldBars = label.quoteBarFrames()
        self.duration = duration
        self.shiftDuration = shiftDuration
        self.wordDuration = wordDuration
        self.fadeWidth = fadeWidth
    }

    var isRunning: Bool { overlay != nil }

    /// 新しい文字列を並べ終えたあとに呼ぶ。
    func start(newText: NSAttributedString) {
        guard let label, label.bounds.width > 0, label.bounds.height > 0 else { return }
        label.layer.setNeedsDisplay()
        label.layer.displayIfNeeded()
        guard let newImage = Self.render(label) else { return }
        let slots = Self.slots(
            old: Self.units(of: oldText, frames: oldFrames),
            new: Self.units(of: newText, frames: EmojiArrivalTransition.characterFrames(of: newText, in: label)),
            duration: duration
        )
        guard !slots.isEmpty else { return }

        let overlay = CALayer()
        overlay.frame = label.bounds
        overlay.masksToBounds = label.numberOfLines > 0
        let now = AppDependencies.mediaTime()
        let oldSize = CGSize(width: oldImage.width, height: oldImage.height)
        let newSize = CGSize(width: newImage.width, height: newImage.height)
        let scale = label.traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 濃さを変える時間は投稿の中でそろえる。短い行だけ速く消えると、前の行の語を追い越すため。前の文字が半分薄くなった語から、新しい文字を出す。
        let fade = Self.fadeDuration(slots: slots, fadeWidth: fadeWidth)
        for slot in slots {
            if let old = slot.old {
                let container = CALayer()
                container.frame = overlay.bounds.offsetBy(dx: 0, dy: slot.oldTargetY - old.rect.minY)
                for word in old.words {
                    let layer = Self.piece(oldImage, source: word, imageSize: oldSize, scale: scale, frame: word)
                    layer.opacity = 0
                    let erase = CABasicAnimation(keyPath: "opacity")
                    erase.fromValue = 1
                    erase.toValue = 0
                    if slot.new == nil {
                        // 新しい本文の高さに入らない行は、先に縮む本文より下のものと重ならないよう、最初に薄くする。
                        erase.duration = shiftDuration * Self.extraLineFadeRatio
                        erase.beginTime = now
                    } else {
                        erase.duration = fade
                        erase.beginTime = now + Self.wordStart(word, in: old, slot: slot)
                    }
                    erase.fillMode = .backwards
                    layer.add(erase, forKey: "fade")
                    container.addSublayer(layer)
                }
                // 大きさは最初に決める。段落の文字も、アクションバーや下の投稿と同じ時刻に新しい位置へ動かす。
                let offset = slot.oldTargetY - old.rect.minY
                if abs(offset) > 0.5 {
                    let move = CASpringAnimation.rowSpring(keyPath: "position", duration: shiftDuration)
                    move.isAdditive = true
                    move.fromValue = CGPoint(x: 0, y: -offset)
                    move.toValue = CGPoint.zero
                    container.add(move, forKey: "move")
                }
                overlay.addSublayer(container)
            }
            if let new = slot.new {
                let rise = new.rect.height * Self.riseRatio
                for word in new.words {
                    let layer = Self.piece(newImage, source: word, imageSize: newSize, scale: scale, frame: word)
                    let begin = now + Self.wordStart(word, in: new, slot: slot) + fade * 0.5
                    let appear = CABasicAnimation(keyPath: "opacity")
                    appear.fromValue = 0
                    appear.toValue = 1
                    appear.duration = fade
                    appear.beginTime = begin
                    appear.fillMode = .backwards
                    layer.add(appear, forKey: "fade")
                    let move = CASpringAnimation.rowSpring(keyPath: "position.y", duration: wordDuration)
                    move.fromValue = layer.position.y + rise
                    move.toValue = layer.position.y
                    move.beginTime = begin
                    move.fillMode = .backwards
                    layer.add(move, forKey: "rise")
                    overlay.addSublayer(layer)
                }
            }
        }
        addBars(to: overlay, image: newImage, imageSize: newSize, scale: scale, label: label)

        let settling = CASpringAnimation.rowSpring(keyPath: "position", duration: shiftDuration).settlingDuration
        let timer = CABasicAnimation(keyPath: "opacity")
        timer.fromValue = 1
        timer.toValue = 1
        let wordSettling = CASpringAnimation.rowSpring(keyPath: "position.y", duration: wordDuration).settlingDuration
        timer.duration = max(Self.erasingEnd(duration: duration, fadeWidth: fadeWidth) + wordSettling, settling)
        timer.delegate = Completion { [weak self, weak overlay] in
            guard let self, let overlay, self.overlay === overlay else { return }
            self.finish()
        }
        overlay.add(timer, forKey: "duration")
        label.layer.contentsRect = .zero
        label.layer.addSublayer(overlay)
        self.overlay = overlay
        hideLabelLayers()
        CATransaction.commit()
    }

    /// 語が動き始める時刻。行の中の読む順の位置で決める。右から左に書く行では、右端が先頭になる。
    static func wordStart(_ word: CGRect, in line: Line, slot: Slot) -> TimeInterval {
        let x0 = min(slot.old?.rect.minX ?? .infinity, slot.new?.rect.minX ?? .infinity)
        let x1 = max(slot.old?.rect.maxX ?? -.infinity, slot.new?.rect.maxX ?? -.infinity)
        let span = max(x1 - x0, 1)
        let isRightToLeft = (line.words.first?.minX ?? 0) > (line.words.last?.minX ?? 0)
        let position = isRightToLeft ? x1 - word.maxX : word.minX - x0
        return slot.start + slot.duration * Double(position / span)
    }

    /// 文字の濃さを変える時間。一番長い行を横切る時間の`fadeWidth`の割合。
    static func fadeDuration(slots: [Slot], fadeWidth: Double) -> TimeInterval {
        (slots.map(\.duration).max() ?? 0) * fadeWidth
    }

    /// 最後の語の前の文字が消え終わる時刻。
    static func erasingEnd(duration: TimeInterval, fadeWidth: Double) -> TimeInterval {
        duration * (1 + fadeWidth)
    }

    private func addBars(to overlay: CALayer, image: CGImage, imageSize: CGSize, scale: CGFloat, label: EmojiLabel) {
        let bars = label.quoteBarFrames()
        for (index, bar) in bars.enumerated() where !bar.isEmpty {
            let layer = Self.piece(image, source: bar, imageSize: imageSize, scale: scale, frame: bar)
            overlay.addSublayer(layer)
            guard oldBars.count == bars.count, oldBars[index] != bar else { continue }
            let from = oldBars[index]
            let resize = CASpringAnimation.rowSpring(keyPath: "bounds", duration: shiftDuration)
            resize.fromValue = CGRect(origin: .zero, size: from.size)
            resize.toValue = layer.bounds
            let move = CASpringAnimation.rowSpring(keyPath: "position", duration: shiftDuration)
            move.fromValue = CGPoint(x: from.midX, y: from.midY)
            move.toValue = layer.position
            layer.add(resize, forKey: "resize")
            layer.add(move, forKey: "move")
        }
    }

    /// ラベルの層の子のうち、動かす層のほかを隠す。並べ直すたびに呼ぶ。
    func hideLabelLayers() {
        guard let overlay, let label else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in label.layer.sublayers ?? [] where layer !== overlay && !layer.isHidden {
            layer.isHidden = true
            hiddenLayers.append(layer)
        }
        CATransaction.commit()
    }

    /// 動きを終え、ラベル自身の描画に戻す。
    func finish() {
        guard let overlay else { return }
        self.overlay = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.removeFromSuperlayer()
        hiddenLayers.forEach { $0.isHidden = false }
        hiddenLayers = []
        label?.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()
    }

    /// 動いている途中の、いま画面に見えている描画。
    func currentImage() -> CGImage? {
        guard isRunning, let label, label.bounds.width > 0, label.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: label.traitCollection)
        return UIGraphicsImageRenderer(bounds: label.bounds, format: format).image { _ in
            label.drawHierarchy(in: label.bounds, afterScreenUpdates: false)
        }.cgImage
    }

    private static func render(_ label: EmojiLabel) -> CGImage? {
        let bounds = label.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: label.traitCollection)
        let mask = label.layer.mask
        label.layer.mask = nil
        defer { label.layer.mask = mask }
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            label.layer.render(in: context.cgContext)
        }.cgImage
    }

    private static func piece(_ image: CGImage, source: CGRect, imageSize: CGSize, scale: CGFloat, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        layer.contentsRect = CGRect(
            x: source.minX * scale / imageSize.width,
            y: source.minY * scale / imageSize.height,
            width: source.width * scale / imageSize.width,
            height: source.height * scale / imageSize.height
        )
        layer.frame = frame
        return layer
    }

    /// 文字ごとの枠を、改行で分けた単位ごとの、行と語の枠の並びにする。語の切れ目に当たらない記号や絵文字は、前の語に含める。
    static func units(of text: NSAttributedString, frames: [Int: CGRect]) -> [[Line]] {
        let string = text.string as NSString
        var wordStarts = Set<Int>()
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            wordStarts.insert(range.location)
        }
        var units: [[Line]] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            var lines: [Line] = []
            for index in frames.keys.sorted() where NSLocationInRange(index, range) {
                guard let frame = frames[index] else { continue }
                if var last = lines.last, frame.midY < last.rect.maxY {
                    last.rect = last.rect.union(frame)
                    if wordStarts.contains(index) {
                        last.words.append(frame)
                    } else {
                        last.words[last.words.count - 1] = last.words[last.words.count - 1].union(frame)
                    }
                    lines[lines.count - 1] = last
                } else {
                    lines.append(Line(rect: frame, words: [frame]))
                }
            }
            if !lines.isEmpty { units.append(lines) }
        }
        return units
    }

    /// 前の行と新しい行を、単位ごとに先頭から組にし、幅に応じて`duration`を割り振る。単位の数が違えば、全体を1つの単位にする。
    static func slots(old: [[Line]], new: [[Line]], duration: TimeInterval) -> [Slot] {
        let pairs: [([Line], [Line])] = old.count == new.count
            ? Array(zip(old, new))
            : [(old.flatMap(\.self), new.flatMap(\.self))]
        var slots: [Slot] = []
        for (unit, pair) in pairs.enumerated() {
            let delta = (pair.1.first?.rect.minY ?? 0) - (pair.0.first?.rect.minY ?? 0)
            for line in 0..<max(pair.0.count, pair.1.count) {
                let oldLine = line < pair.0.count ? pair.0[line] : nil
                let newLine = line < pair.1.count ? pair.1[line] : nil
                let target = newLine?.rect.minY ?? ((oldLine?.rect.minY ?? 0) + delta)
                slots.append(Slot(unit: unit, old: oldLine, new: newLine, oldTargetY: target, start: 0, duration: 0))
            }
        }
        // 新しい行のない前の行は最初に薄くするので、順番の時間を割り振らない。
        let widths = slots.map { slot -> CGFloat in
            guard slot.new != nil else { return 0 }
            return max(slot.old?.rect.maxX ?? 0, slot.new?.rect.maxX ?? 0) - min(slot.old?.rect.minX ?? .infinity, slot.new?.rect.minX ?? .infinity)
        }
        let total = max(widths.reduce(0, +), 1)
        var elapsed: TimeInterval = 0
        for index in slots.indices {
            let share = duration * Double(widths[index] / total)
            slots[index].start = elapsed
            slots[index].duration = share
            elapsed += share
        }
        return slots
    }

    @MainActor
    private final class Completion: NSObject, @MainActor CAAnimationDelegate {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        func animationDidStop(_ animation: CAAnimation, finished: Bool) {
            handler()
        }
    }
}
