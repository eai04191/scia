import UIKit

/// カスタム絵文字の画像が、読み込み中に空けていた場所に入るときの動き。
///
/// 届いた画像の幅が空けていた正方形と違うと、同じ行のあとの文字が横へずれ、折り返しが変われば次の行へ移る。
/// 新しい描画を1枚の画像にし、同じだけ動く文字のまとまりごとに切り出して、前の位置から新しい位置へ動かす。
/// 次の行へ移る文字は、行をまたいで動く。新しく入った絵文字は、新しい位置で薄い状態から濃くする。
/// 動かしている間は、ラベル自身の描画と動く絵文字の層を隠し、切り出した像だけを見せる。
///
/// 1つの文字列の絵文字は、少しずつずれて届く。動いている途中に次の絵文字が届いたら、いま見えている位置と濃さから、
/// 次の並びの位置へ動かし直す。打ち切って最後の位置へ飛ばすと、届くたびに1コマで動いて見えるため。
@MainActor
final class EmojiArrivalTransition {
    /// 文字が見えている位置と濃さ。
    struct Placement: Equatable {
        var frame: CGRect
        var opacity: Float
    }

    /// 切り出して動かす1まとまり。
    struct Piece: Equatable {
        /// まとまりに入る文字の、先頭のUTF-16の位置。
        var indices: [Int]
        /// 新しい並びでの枠。ラベルの座標。
        var frame: CGRect
        /// 動き始める位置から新しい位置までの動き。
        var offset: CGPoint
        /// 動き始めるときの濃さ。新しく入った絵文字は0から濃くする。
        var startOpacity: Float
    }

    /// 動き始めるときの、文字ごとの見え方。キーは文字（書記素クラスタ）の先頭のUTF-16の位置。
    private let start: [Int: Placement]
    private let duration: TimeInterval
    private var overlay: CALayer?
    private var pieceLayers: [(piece: Piece, layer: CALayer)] = []
    /// 新しい並びでの、文字ごとの枠。
    private var finalFrames: [Int: CGRect] = [:]
    private var hiddenLayers: [CALayer] = []
    private weak var label: EmojiLabel?

    /// 文字列を入れ替える前に呼ぶ。`start`は、動き始めるときの文字ごとの見え方。
    init(label: EmojiLabel, start: [Int: Placement], duration: TimeInterval) {
        self.label = label
        self.start = start
        self.duration = duration
    }

    /// 動かしている途中。
    var isRunning: Bool { overlay != nil }

    /// 前の文字列を`label`の幅で並べたときの、文字ごとの見え方。`filled`は、これから画像が入る、空けていた絵文字の位置で、濃さを0にする。
    static func placements(of text: NSAttributedString, in label: EmojiLabel, filling filled: Set<Int>) -> [Int: Placement] {
        characterFrames(of: text, in: label).reduce(into: [:]) { result, entry in
            result[entry.key] = Placement(frame: entry.value, opacity: filled.contains(entry.key) ? 0 : 1)
        }
    }

    /// 動いている途中の、いま見えている文字ごとの位置と濃さ。動いている途中に次の絵文字が届いたとき、そこから動かし直すのに使う。
    /// `filled`は、これから画像が入る、空けていた絵文字の位置で、濃さを0にする。
    func currentPlacements(filling filled: Set<Int>) -> [Int: Placement] {
        var result: [Int: Placement] = [:]
        for (piece, layer) in pieceLayers {
            let presentation = layer.presentation()
            let position = presentation?.position ?? layer.position
            let dx = position.x - layer.position.x
            let dy = position.y - layer.position.y
            let opacity = presentation?.opacity ?? layer.opacity
            for index in piece.indices {
                guard let frame = finalFrames[index] else { continue }
                result[index] = Placement(frame: frame.offsetBy(dx: dx, dy: dy), opacity: filled.contains(index) ? 0 : opacity)
            }
        }
        return result
    }

    /// 新しい文字列を並べ終えたあとに呼び、動き始める見え方から新しい位置へ動かす。
    func start(newText: NSAttributedString) {
        guard let label, label.bounds.width > 0, label.bounds.height > 0 else { return }
        finalFrames = Self.characterFrames(of: newText, in: label)
        let pieces = Self.pieces(start: start, final: finalFrames)
        guard !pieces.isEmpty else { return }
        label.layer.setNeedsDisplay()
        label.layer.displayIfNeeded()
        let bounds = label.bounds
        let format = UIGraphicsImageRendererFormat(for: label.traitCollection)
        // 行末をぼかすラベル（`FadingLabel`）のマスクは、像に焼き込まない。像はラベルの層の中に置くので、マスクは表示のときに一度だけかかる。
        let mask = label.layer.mask
        label.layer.mask = nil
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            label.layer.render(in: context.cgContext)
        }.cgImage
        label.layer.mask = mask
        guard let image else { return }

        let overlay = CALayer()
        overlay.frame = bounds
        // 行数を限るラベルでは、並べた範囲の外の文字まで切り出すことがあるため、ラベルの外へはみ出させない。
        // 限らないラベルでは切らない。折り返しが減ってラベルが低くなると、前の最後の行から上がってくる文字が、新しい枠の外から動き始めるため。
        overlay.masksToBounds = label.numberOfLines > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for piece in pieces {
            let layer = CALayer()
            layer.contents = image
            layer.contentsScale = format.scale
            layer.contentsRect = CGRect(
                x: piece.frame.minX / bounds.width,
                y: piece.frame.minY / bounds.height,
                width: piece.frame.width / bounds.width,
                height: piece.frame.height / bounds.height
            )
            layer.frame = piece.frame
            overlay.addSublayer(layer)
            pieceLayers.append((piece, layer))
            if piece.startOpacity < 1 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = piece.startOpacity
                fade.toValue = 1
                fade.duration = duration
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "fadeIn")
            }
            if piece.offset != .zero {
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = CGPoint(x: layer.position.x - piece.offset.x, y: layer.position.y - piece.offset.y)
                move.toValue = layer.position
                move.duration = duration
                move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(move, forKey: "move")
            }
        }
        // どのまとまりも同じ時間で動くので、時間を測るためだけの動きを足し、その終わりで外す。
        // 外側の描き直しの中で始めるため、CATransactionの完了は動きの終わりを待たずに呼ばれる（シミュレーターで確かめた）。
        let timer = CABasicAnimation(keyPath: "opacity")
        timer.fromValue = 1
        timer.toValue = 1
        timer.duration = duration
        timer.delegate = Completion { [weak self, weak overlay] finished in
            guard let self, let overlay, self.overlay === overlay else { return }
            self.finish()
        }
        overlay.add(timer, forKey: "duration")
        // ラベル自身の描画（文字の中の静止画を含む）と、動く絵文字の層を隠す。像に描き込んであるため。
        label.layer.contentsRect = .zero
        label.layer.addSublayer(overlay)
        self.overlay = overlay
        hideLabelLayers()
        CATransaction.commit()
    }

    /// ラベルの層の子のうち、像のほかを隠す。動いている途中に動く絵文字のアニメーション版が届くと、ラベルが並べ直して層を出し直すため、
    /// 並べ直すたびに呼ぶ。
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

    /// 動きを終え、ラベル自身の描画に戻す。使い回された行で別の文字列に替わったときも呼ぶ。
    func finish() {
        guard let overlay else { return }
        self.overlay = nil
        pieceLayers = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.removeFromSuperlayer()
        hiddenLayers.forEach { $0.isHidden = false }
        hiddenLayers = []
        label?.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()
    }

    /// 動きの終わりを受け取る。
    @MainActor
    private final class Completion: NSObject, @MainActor CAAnimationDelegate {
        private let handler: (Bool) -> Void

        init(_ handler: @escaping (Bool) -> Void) {
            self.handler = handler
        }

        func animationDidStop(_ animation: CAAnimation, finished: Bool) {
            handler(finished)
        }
    }

    /// 文字を、同じ行に並び、同じだけ動き、同じ濃さから始まる、続いた文字のまとまりに分ける。動き始める見え方がない文字（並べた範囲の外）は動かさない。
    static func pieces(start: [Int: Placement], final: [Int: CGRect]) -> [Piece] {
        var pieces: [Piece] = []
        var current: Piece?
        for index in final.keys.sorted() {
            guard let frame = final[index] else { continue }
            let from = start[index]
            let offset = from.map { CGPoint(x: frame.minX - $0.frame.minX, y: frame.minY - $0.frame.minY) } ?? .zero
            let opacity = from?.opacity ?? 1
            if var piece = current, piece.startOpacity == opacity,
               abs(piece.offset.x - offset.x) < 0.5, abs(piece.offset.y - offset.y) < 0.5,
               abs(piece.frame.minY - frame.minY) < 0.5 {
                piece.frame = piece.frame.union(frame)
                piece.indices.append(index)
                current = piece
                continue
            }
            if let current { pieces.append(current) }
            current = Piece(indices: [index], frame: frame, offset: offset, startOpacity: opacity)
        }
        if let current { pieces.append(current) }
        return pieces
    }

    /// 文字ごとの、`label`の幅で並べたときの枠。
    private static func characterFrames(of text: NSAttributedString, in label: EmojiLabel) -> [Int: CGRect] {
        let layout = label.textLayout(of: text)
        let string = text.string as NSString
        var frames: [Int: CGRect] = [:]
        var index = 0
        while index < string.length {
            let cluster = string.rangeOfComposedCharacterSequence(at: index)
            if let frame = label.characterFrame(at: index, in: text, contentStorage: layout.contentStorage, layoutManager: layout.layoutManager), !frame.isEmpty {
                frames[index] = frame
            }
            index = cluster.location + cluster.length
        }
        return frames
    }
}
