import UIKit

/// 本文の先頭の空き（`RichTextRenderer.marksTranslation`）に重ねる、自動翻訳のマーク。訳文を待つ間はパルスさせ、届いたら同じ場所で止める。
/// 決まりはdocs/auto-translation.mdの「見せ方」にある。
final class TranslationMarkView: UIImageView {
    private var pulses = false

    init() {
        super.init(image: UIImage(systemName: "translate"))
        contentMode = .scaleAspectFit
        tintColor = .secondaryLabel
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - pulses: 訳文を待っているか。マークを出さなければnil。
    ///   - keepsPulse: 同じ本文で、前から訳文を待っていた。パルスを最初からやり直さない。使い回したビューのパルスは止まっていることがあるので、別の本文に替わったら付け直す。
    func apply(pulses newPulses: Bool?, keepsPulse: Bool) {
        isHidden = newPulses == nil
        let newPulses = newPulses ?? false
        if newPulses, !(pulses && keepsPulse) {
            removeAllSymbolEffects()
            addSymbolEffect(.pulse, options: .repeat(.continuous))
        } else if !newPulses, pulses {
            removeAllSymbolEffects()
        }
        pulses = newPulses
    }

    /// `label`の先頭の空きに合わせて置く。`container`はこのビューを載せているビュー。
    func layout(over label: EmojiLabel, in container: UIView) {
        guard !isHidden, let frame = label.attachmentFrame(at: 0) else { return }
        self.frame = label.convert(frame, to: container)
    }
}
