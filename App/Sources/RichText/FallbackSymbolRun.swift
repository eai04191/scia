import CoreText
import UIKit

extension NSAttributedString.Key {
    /// 標準の書体にない記号に付ける属性。描き方は変えず、後ろの漢字やかなと属性のランを分けるためだけに付ける（`separateFallbackSymbols`）。
    static let fallbackSymbol = NSAttributedString.Key("net.mizle.scia.fallbackSymbol")
}

extension NSMutableAttributedString {
    /// 標準の書体にない記号のうち、漢字やかなが続くものに属性を付け、漢字やかなと属性のランを分ける。`range`にかかる段落を付け直す。
    /// 標準の書体にない文字が続く間、システムは先に使った書体を先に試す。「𝕏」を描けるSTIXは「の」も持つため、
    /// 「𝕏あいうの」では、離れた「の」までSTIXで描かれていた。ランが分かれると、漢字とかなの書体を言語の設定から選び直す。
    /// ランが分かれると、分かれたランごとにシステムが書体を探し直す。漢字とかなの側に属性を付けると、英字と混ざるたびにランが分かれ、
    /// iOSのシミュレーターで並べる時間が約3倍になったため、記号の側に、漢字やかなが続くときだけ付ける。
    func separateFallbackSymbols(in range: NSRange) {
        guard length > 0 else { return }
        let string = self.string as NSString
        // 属性を付けるかは後ろに続く文字で決まり、入力欄で打った文字は手前の属性を引き継いで入るため、段落ごと外して付け直す。
        let location = min(range.location, length)
        let paragraphs = string.paragraphRange(for: NSRange(location: location, length: min(range.length, length - location)))
        removeAttribute(.fallbackSymbol, range: paragraphs)
        // 標準の書体にない記号が続いている範囲。漢字かかなに行き当たったら属性を付ける。
        var symbols: NSRange?
        var next = paragraphs.location
        while next < NSMaxRange(paragraphs) {
            // 異体字セレクターとの間でランを分けると、選んだ字形でなくなるため、書記素クラスタごとに見る。
            let cluster = string.rangeOfComposedCharacterSequence(at: next)
            switch kind(of: string.substring(with: cluster), at: cluster.location) {
            case .cjk:
                if let symbols {
                    addAttribute(.fallbackSymbol, value: true, range: symbols)
                }
                symbols = nil
            case .symbol:
                symbols = symbols.map { NSUnionRange($0, cluster) } ?? cluster
            case .neutral:
                break
            case .covered:
                symbols = nil
            }
            next = NSMaxRange(cluster)
        }
    }

    private enum ClusterKind {
        case cjk
        /// 標準の書体にない、漢字とかな以外の文字。
        case symbol
        /// 絵文字とカスタム絵文字の画像。絵文字の書体はかなを持たないため属性を付けず、前の記号が続く範囲も切らない。
        case neutral
        /// 標準の書体で描ける文字と空白。代わりの書体を使い続ける範囲が、ここで切れる。
        case covered
    }

    private func kind(of cluster: String, at location: Int) -> ClusterKind {
        guard let first = cluster.unicodeScalars.first else { return .covered }
        if Self.isCJK(first) { return .cjk }
        if first.properties.isEmojiPresentation || cluster.unicodeScalars.contains("\u{FE0F}") || first == "\u{FFFC}" { return .neutral }
        guard !first.properties.isWhitespace, let font = attribute(.font, at: location, effectiveRange: nil) as? UIFont else { return .covered }
        let characters = Array(String(first).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count) ? .covered : .symbol
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF: true
        default: false
        }
    }
}
