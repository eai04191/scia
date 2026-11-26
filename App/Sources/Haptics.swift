import SciaCore
import UIKit

extension HapticStyle {
    /// ハプティクスを鳴らす。`intensity`が0なら鳴らさない。`selection`は強さを選べないので、`intensity`は鳴らすかどうかだけに使う。
    @MainActor
    func play(intensity: Double, in view: UIView, at location: CGPoint) {
        guard intensity > 0 else { return }
        let impact: UIImpactFeedbackGenerator.FeedbackStyle
        switch self {
        case .light: impact = .light
        case .medium: impact = .medium
        case .heavy: impact = .heavy
        case .soft: impact = .soft
        case .rigid: impact = .rigid
        case .selection:
            UISelectionFeedbackGenerator(view: view).selectionChanged(at: location)
            return
        }
        UIImpactFeedbackGenerator(style: impact, view: view).impactOccurred(intensity: intensity, at: location)
    }
}
