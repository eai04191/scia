import SciaCore
import UIKit

/// プロフィールの補足情報のカードと固定された投稿のカード、画面のティントカラーに付ける色。
/// 色の決め方は`ProfileCardPalette`にあり、ここではUIKitの色に直してカードに当てる。
@MainActor
struct ProfileAccentAppearance {
    /// カードの地の色。塗りつぶしたボタンもこの色で塗る。
    let background: UIColor
    /// 本文、リンク、確認済みのチェックマーク、塗りつぶしたボタンの文字の色（白か黒）。
    let text: UIColor
    /// 白い文字で描く。falseなら黒い文字で描く。
    let usesLightText: Bool
    /// 控えめな文字の色。
    let secondaryText: UIColor
    /// カードの中の区切り線の色。
    let separator: UIColor
    /// 画面のティントカラー。
    let screenTint: UIColor
    /// カードの外のリンクと「さらに表示」に下線を引く。
    let underlinesScreenLinks: Bool

    init(palette: ProfileCardPalette) {
        background = Self.uiColor(palette.background)
        usesLightText = palette.usesLightText
        text = palette.usesLightText ? .white : .black
        secondaryText = switch palette.secondaryText {
        case .toned(let color): Self.uiColor(color)
        case .translucent(let alpha): UIColor(white: palette.usesLightText ? 1 : 0, alpha: alpha)
        }
        separator = UIColor(white: palette.usesLightText ? 1 : 0, alpha: palette.separatorAlpha)
        screenTint = Self.uiColor(palette.screenTint)
        underlinesScreenLinks = palette.underlinesScreenLinks
    }

    /// カードに色を付ける。中の本文の色（`label`）が白か黒になるよう、カードの見た目をダークかライトに固定する。
    func apply(to card: UIView) {
        card.backgroundColor = background
        card.overrideUserInterfaceStyle = usesLightText ? .dark : .light
        // 地に敷くカードでは、リンクも本文と同じ白か黒にし、下線で見分ける。
        card.tintColor = text
    }

    /// 色を外し、システムの色に戻す。
    static func reset(_ card: UIView) {
        card.backgroundColor = .secondarySystemFill
        card.overrideUserInterfaceStyle = .unspecified
        card.tintColor = nil
    }

    /// カードの中のラベルの文字のうち、控えめな文字（`secondaryLabel`）の部分を`color`に塗り替える。nilなら`secondaryLabel`に戻す。
    /// 塗り替えた部分には印の属性を付け、ダークモードへの切り替えなどで塗り直せるようにする。
    static func recolorSecondaryText(in view: UIView, to color: UIColor?) {
        if let label = view as? UILabel, let text = Self.originalText(of: label), text.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: text)
            var changed = false
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                let isMarked = attributes[.profileAccentSecondary] != nil
                guard isMarked || (attributes[.foregroundColor] as? UIColor) == UIColor.secondaryLabel else { return }
                if let color {
                    mutable.addAttribute(.foregroundColor, value: color, range: range)
                    mutable.addAttribute(.profileAccentSecondary, value: true, range: range)
                } else {
                    mutable.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                    mutable.removeAttribute(.profileAccentSecondary, range: range)
                }
                changed = true
            }
            if changed { label.attributedText = mutable }
        }
        for subview in view.subviews {
            recolorSecondaryText(in: subview, to: color)
        }
    }

    /// ラベルの中のリンクに下線を引くか外し、確認済みのチェックマークを`badge`の色で描き直す。`badge`がnilなら緑に戻す。
    /// 下線とチェックマークには印の属性を付け、外すときに、もともと引いてあった下線には触れないようにする。
    static func restyleLinks(in view: UIView, underline: Bool, badge: UIColor?) {
        if let label = view as? UILabel, let text = Self.originalText(of: label), text.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: text)
            var changed = false
            let whole = NSRange(location: 0, length: text.length)
            text.enumerateAttribute(.linkDestination, in: whole) { destination, range, _ in
                guard destination != nil else { return }
                let isMarked = text.attribute(.profileAccentUnderline, at: range.location, effectiveRange: nil) != nil
                if underline, !isMarked {
                    mutable.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .profileAccentUnderline: true], range: range)
                    changed = true
                } else if !underline, isMarked {
                    mutable.removeAttribute(.underlineStyle, range: range)
                    mutable.removeAttribute(.profileAccentUnderline, range: range)
                    changed = true
                }
            }
            text.enumerateAttribute(.profileVerifiedBadge, in: whole) { marked, range, _ in
                guard marked != nil, let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                      let image = attachment.image
                else { return }
                mutable.addAttribute(.attachment, value: NSTextAttachment(image: image.withTintColor(badge ?? .systemGreen, renderingMode: .alwaysOriginal)), range: range)
                changed = true
            }
            if changed { label.attributedText = mutable }
        }
        for subview in view.subviews {
            restyleLinks(in: subview, underline: underline, badge: badge)
        }
    }

    /// ラベルに置いた元の文字列。絵文字を差し替えて描いているラベルでは、差し替える前のもの。
    private static func originalText(of label: UILabel) -> NSAttributedString? {
        (label as? EmojiLabel)?.originalAttributedText ?? label.attributedText
    }

    static func uiColor(_ color: ProfileAccentColor) -> UIColor {
        let p3 = color.displayP3
        return UIColor(displayP3Red: p3.red, green: p3.green, blue: p3.blue, alpha: 1)
    }
}

extension ProfileCardPalette.Options {
    /// チューニングの値で作る。
    @MainActor
    init(tuning: TuningStore) {
        self.init()
        body = ContrastTarget(ratio: tuning.value(of: TuningCatalog.profileAccentBodyContrast), lc: tuning.value(of: TuningCatalog.profileAccentBodyLc))
        secondary = ContrastTarget(ratio: tuning.value(of: TuningCatalog.profileAccentSecondaryContrast), lc: tuning.value(of: TuningCatalog.profileAccentSecondaryLc))
        tintsSecondaryText = tuning.value(of: TuningCatalog.profileAccentTintsText)
        darkLightness = tuning.value(of: TuningCatalog.profileAccentDarkLightness)
        darkNeutralMaxLightness = tuning.value(of: TuningCatalog.profileAccentDarkNeutralMaxLightness)
    }
}

extension NSAttributedString.Key {
    /// カードの色で塗り替えた控えめな文字の印。
    static let profileAccentSecondary = NSAttributedString.Key("scia.profileAccentSecondary")
    /// カードの色のために引いたリンクの下線の印。
    static let profileAccentUnderline = NSAttributedString.Key("scia.profileAccentUnderline")
    /// 補足情報の確認済みのチェックマークの印。カードの色に合わせて描き直すときに探す。
    static let profileVerifiedBadge = NSAttributedString.Key("scia.profileVerifiedBadge")
}

extension ProfileAccentColor {
    /// UIImageから色を作る。動く画像は最初のコマで作る。
    init?(uiImage: UIImage) {
        guard let cgImage = uiImage.images?.first?.cgImage ?? uiImage.cgImage else { return nil }
        self.init(image: cgImage)
    }
}
