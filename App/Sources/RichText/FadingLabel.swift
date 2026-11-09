import UIKit

/// 1行に入りきらないときに、「…」で切らず、行末を透明へ向けてぼかすラベル。入りきるときは何もかけない。
/// 行末のぼかしはラベルの層のマスクでかけるので、重ねた動くカスタム絵文字の層も一緒にぼける。
final class FadingLabel: EmojiLabel {
    /// 行末をぼかす幅。
    var fadeWidth: CGFloat = 20 {
        didSet { setNeedsLayout() }
    }

    private let fadeMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 名前の文字列には、RichTextRendererが単語で折り返す段落スタイルを付けている。段落スタイルはlineBreakModeより優先され、
    /// 単語の切れ目で切れて行末まで文字が届かないため、段落スタイルも行末で切る形に書き換える。
    override var attributedText: NSAttributedString? {
        get { super.attributedText }
        set {
            super.attributedText = newValue.map(Self.clipping)
            setNeedsLayout()
        }
    }

    private static func clipping(_ text: NSAttributedString) -> NSAttributedString {
        let clipped = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: clipped.length)
        var styles: [(NSRange, NSParagraphStyle?)] = []
        clipped.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            styles.append((range, value as? NSParagraphStyle))
        }
        for (range, style) in styles {
            let mutable = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            mutable.lineBreakMode = .byClipping
            clipped.addAttribute(.paragraphStyle, value: mutable, range: range)
        }
        return clipped
    }

    /// 文字列の書字方向が右から左か。Unicodeの双方向アルゴリズムが段落の向きを決めるのと同じく、最初に向きの決まる文字で決める。
    /// 絵文字や記号、数字は向きを決めないため読み飛ばす。向きの決まる文字がなければ左から右とする。
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // ヘブライ文字、アラビア文字、シリア文字、ターナ文字、ンコ文字など、と、その表示形。
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                if scalar.properties.isAlphabetic {
                    return false
                }
            }
        }
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        Self.updateFade(fadeMask, on: self, isTruncated: intrinsicContentSize.width > bounds.width + 0.5, fadeWidth: fadeWidth)
    }

    /// 入りきらないラベルの層に、行末を透明へ向けてぼかすマスクをかける。入りきるときは外す。ボタンのタイトルなど、FadingLabelにできないラベルにも使う。
    static func updateFade(_ fadeMask: CAGradientLayer, on label: UILabel, isTruncated: Bool, fadeWidth: CGFloat) {
        guard isTruncated, label.bounds.width > 0 else {
            label.layer.mask = nil
            return
        }
        CATransaction.begin()
        // セルの再利用やスクロール中に、マスクが前の位置から動いて見えないようにする。
        CATransaction.setDisableActions(true)
        fadeMask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        fadeMask.frame = label.bounds
        let fade = min(fadeWidth, label.bounds.width) / label.bounds.width
        // 右から左に書く文字列では、行末は左端になる。画面の向きではなく、文字列の向きで決める。
        let isRightToLeft = isRightToLeft(label.attributedText?.string ?? label.text ?? "")
        fadeMask.startPoint = CGPoint(x: isRightToLeft ? fade : 1 - fade, y: 0.5)
        fadeMask.endPoint = CGPoint(x: isRightToLeft ? 0 : 1, y: 0.5)
        CATransaction.commit()
        label.layer.mask = fadeMask
    }
}

/// タイトルが入りきらないときに、「…」で切らず、FadingLabelと同じく行末を透明へ向けてぼかすボタン。
/// `UIButton.Configuration`のタイトルを`.byClipping`で切らせ、ボタンが置いたタイトルのラベルにマスクをかける。
final class FadingTitleButton: UIButton {
    /// 行末をぼかす幅。
    var fadeWidth: CGFloat = 16 {
        didSet { setNeedsLayout() }
    }

    private let fadeMask = CAGradientLayer()

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let titleLabel else { return }
        FadingLabel.updateFade(fadeMask, on: titleLabel, isTruncated: titleLabel.intrinsicContentSize.width > titleLabel.bounds.width + 0.5, fadeWidth: fadeWidth)
    }
}
