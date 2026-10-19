#if DEBUG
import CoreImage
import SciaCore
import UIKit

/// HDRのカスタム絵文字が、本文の中でどう描かれるか。本文の中の絵文字は`UIImageView`ではなく文字と一緒に描くため、
/// HDRの設定が効いているかを、同じ画像を`UIImageView`でSDR、控えめなHDR、HDRに指定したものと並べて見比べる。
/// シミュレーターはHDRの画像を光らせないので、実機で見る。
enum HDREmojiCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "本文の中の絵文字（いまの描き方）と、同じ画像をSDR、控えめなHDR、HDRで描いたもの。本文の中がSDRと同じ明るさなら光っていない") {
                comparison()
            },
        ]
    }

    /// 明るさの余地を持つ黄色い丸のHLGのPNG。stellaria.networkの「HDR玉」（:large_yellow_circle_hdr:）と同じく、HLGの画像にする。
    private static let pngData: Data? = {
        let size = CGSize(width: 160, height: 160)
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG),
              let yellow = CIColor(red: 3, green: 3, blue: 0, alpha: 1, colorSpace: linear)
        else { return nil }
        let circle = CIImage(color: yellow).cropped(to: CGRect(origin: .zero, size: size))
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: size.width / 2, y: size.height / 2),
            "inputRadius0": size.width / 2 - 2,
            "inputRadius1": size.width / 2,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear,
        ])?.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
        let image = mask.map { circle.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: $0]) } ?? circle
        return CIContext().pngRepresentation(of: image, format: .RGBA16, colorSpace: hlg)
    }()

    @MainActor
    private static func comparison() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        guard let data = pngData, let url = URL(string: "data:image/png;base64,\(data.base64EncodedString())") else {
            let label = UILabel()
            label.text = "HDRの画像を作れませんでした"
            stack.addArrangedSubview(label)
            return stack
        }
        let emoji = CustomEmoji(shortcode: "hdr_circle", url: url, staticUrl: url)
        let renderer = RichTextRenderer(
            font: .preferredFont(forTextStyle: .largeTitle),
            textColor: .label,
            emojiImages: AppDependencies.emojiImages,
            language: "ja"
        )
        let text = RichText.plain("本文の中 :hdr_circle:", emojis: [emoji])
        let label = UILabel()
        label.attributedText = renderer.render(text)
        // 絵文字の画像は後から届くので、届いたら描き直す。
        AppDependencies.emojiImages.addListener(owner: label) { [weak label] _ in
            label?.attributedText = renderer.render(text)
        }
        stack.addArrangedSubview(label)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 16
        let image = UIImage(data: data)
        for (title, range) in [("SDR", UIImage.DynamicRange.standard), ("控えめなHDR", .constrainedHigh), ("HDR", .high)] {
            let column = UIStackView()
            column.axis = .vertical
            column.alignment = .center
            column.spacing = 4
            let imageView = UIImageView(image: image)
            imageView.preferredImageDynamicRange = range
            imageView.contentMode = .scaleAspectFit
            imageView.widthAnchor.constraint(equalToConstant: 44).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 44).isActive = true
            let caption = UILabel()
            caption.text = title
            caption.font = .preferredFont(forTextStyle: .caption1)
            column.addArrangedSubview(imageView)
            column.addArrangedSubview(caption)
            row.addArrangedSubview(column)
        }
        stack.addArrangedSubview(row)
        return stack
    }
}
#endif
