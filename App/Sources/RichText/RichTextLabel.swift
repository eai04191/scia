import SwiftUI
import SciaCore
import UIKit

/// RichTextRendererで描いた文字列を、SwiftUIの中に出す。SwiftUIのTextはカスタム絵文字の画像を描けないため、UILabelを使う。
/// 絵文字の画像が後から届いたら描き直す。
struct RichTextLabel: UIViewRepresentable {
    let numberOfLines: Int
    let emojiImages: EmojiImageStore<UIImage>
    /// アニメーションするカスタム絵文字を動かすか。
    let animatesEmojis: Bool
    /// 1行に入りきらないときに、「…」で切らず、行末をぼかす（`FadingLabel`）。
    let fadesTail: Bool
    let render: @MainActor () -> NSAttributedString

    init(numberOfLines: Int = 0, emojiImages: EmojiImageStore<UIImage> = AppDependencies.emojiImages, animatesEmojis: Bool = false, fadesTail: Bool = false, render: @escaping @MainActor () -> NSAttributedString) {
        self.numberOfLines = numberOfLines
        self.emojiImages = emojiImages
        self.animatesEmojis = animatesEmojis
        self.fadesTail = fadesTail
        self.render = render
    }

    func makeUIView(context: Context) -> EmojiLabel {
        let label = fadesTail ? FadingLabel() : EmojiLabel()
        label.numberOfLines = numberOfLines
        // FadingLabelは自分で行末で切るよう設定する。
        if !fadesTail {
            label.lineBreakMode = .byTruncatingTail
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let coordinator = context.coordinator
        emojiImages.addListener(owner: coordinator) { [weak label, weak coordinator] _ in
            guard let label, let render = coordinator?.render else { return }
            label.attributedText = render()
            label.invalidateIntrinsicContentSize()
        }
        return label
    }

    func updateUIView(_ label: EmojiLabel, context: Context) {
        context.coordinator.render = render
        label.numberOfLines = numberOfLines
        label.emojiImages = animatesEmojis ? emojiImages : nil
        label.attributedText = render()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: EmojiLabel, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var render: (@MainActor () -> NSAttributedString)?
    }
}

extension UIFont {
    /// 同じ大きさの太字。
    var bold: UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}
