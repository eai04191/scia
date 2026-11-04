import UIKit

/// 引用の段落の頭に引く縦線。`RichTextRenderer`が引用の段落に属性（`.quoteBars`）として付け、`EmojiLabel`が文字と一緒に描く。
/// 線は引用の深さの数だけ、1段ごとの字下げの頭に引く。続く行と段落が同じ深さの引用なら、段落のあいだもつなげて1本にする。
final class QuoteBars: NSObject, Sendable {
    /// 引用の深さ。
    let level: Int
    /// 1段あたりの字下げ。線は、各段の字下げの頭に引く。
    let indentPerLevel: CGFloat
    /// 線の太さ。
    let width: CGFloat

    /// 線の色。
    static let color = UIColor.tertiaryLabel

    init(level: Int, indentPerLevel: CGFloat, width: CGFloat) {
        self.level = level
        self.indentPerLevel = indentPerLevel
        self.width = width
    }

    // 文字列の中身を比べる`EmojiLabel.hasSameContent`は、属性を`isEqual`で比べる。描き直すたびに作り直しても、同じ線なら同じとみなす。
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? QuoteBars else { return false }
        return level == other.level && indentPerLevel == other.indentPerLevel && width == other.width
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(level)
        hasher.combine(indentPerLevel)
        hasher.combine(width)
        return hasher.finalize()
    }

    /// `text`に引用の縦線を引く段落があるか。なければ、行を並べて調べずに済ませる。
    static func appear(in text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.quoteBars, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// `layout`に並べた文字の、引用の縦線の枠。`bounds`より下の行には引かない。
    /// 線の上端は最初の行の上端、下端は最後の行の字面の下端（ベースラインから行の下の長さ）にする。最後の行の下の行間までは伸ばさない。
    /// 字下げは段落の書き始めの側に空くので、線も段落の書く向きで、右から左に書く段落なら右端から測る。画面の向きでは決めない。
    /// 段落の寄せ方は画面の向きで決めている（`TextKitLabelLayout.aligned`）ため、画面と段落の向きが違うと、字下げは寄せた側の反対に空く。
    static func frames(in layout: TextLayout, bounds: CGRect) -> [CGRect] {
        var open: [Int: (bars: QuoteBars, isRightToLeft: Bool, top: CGFloat, bottom: CGFloat)] = [:]
        var frames: [CGRect] = []
        func close(_ level: Int) {
            guard let bar = open.removeValue(forKey: level) else { return }
            let offset = CGFloat(level) * bar.bars.indentPerLevel
            let x = bar.isRightToLeft ? bounds.width - offset - bar.bars.width : offset
            frames.append(CGRect(x: x, y: bar.top, width: bar.bars.width, height: bar.bottom - bar.top))
        }
        let layoutManager = layout.layoutManager
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            let isRightToLeft = layoutManager.baseWritingDirection(at: fragment.rangeInElement.location) == .rightToLeft
            for line in fragment.textLineFragments {
                let top = origin.y + line.typographicBounds.minY
                guard top < bounds.maxY else { return false }
                // 文字のない行（空の段落）は、前後の線を切らずにそのまま続ける。
                guard line.characterRange.length > 0 else { continue }
                let bars = line.attributedString.attribute(.quoteBars, at: line.characterRange.location, effectiveRange: nil) as? QuoteBars
                let level = bars?.level ?? 0
                let bottom = top + line.glyphOrigin.y + TextKitLabelLayout.descent(of: line)
                for index in 0..<max(level, (open.keys.max() ?? -1) + 1) {
                    guard index < level, let bars else {
                        close(index)
                        continue
                    }
                    // 書く向きの違う段落に移ったら、線を引く側が変わるので、そこで切る。
                    if let start = open[index], start.isRightToLeft != isRightToLeft {
                        close(index)
                    }
                    let start = open[index]
                    open[index] = (start?.bars ?? bars, isRightToLeft, start?.top ?? top, bottom)
                }
            }
            return true
        }
        for level in open.keys.sorted() {
            close(level)
        }
        return frames
    }
}

extension NSAttributedString.Key {
    /// 引用の段落の頭に引く縦線（`QuoteBars`）。
    static let quoteBars = NSAttributedString.Key("net.mizle.scia.quoteBars")
}
