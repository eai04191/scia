#if DEBUG
import SciaCore
import UIKit

/// 開発用。画面がSDRの白の何倍まで明るく描けるか（今の余地と最大の余地）と、お気に入りとブーストの光をHDRとSDRのどちらで描くかを、画面の隅に出し続ける。
/// 今の余地は画面の明るさや周りの明るさで変わるが、変わったことを知らせる通知がないため、出している間は一定の間隔で読み直す。
/// 晴れた屋外などで、余地がどこまで下がるか、HDRの内容がないと1に戻るかを、実機で確かめるために使う。
@MainActor
enum EDRHeadroomOverlay {
    /// チューニングのスイッチに合わせて、`window`に出したり消したりする。
    static func follow(_ window: UIWindow, tuning: TuningStore) {
        withObservationTracking {
            apply(tuning.value(of: TuningCatalog.debugShowsEDRHeadroom), to: window)
        } onChange: { [weak window] in
            Task { @MainActor in
                guard let window else { return }
                follow(window, tuning: tuning)
            }
        }
    }

    private static func apply(_ isShown: Bool, to window: UIWindow) {
        let existing = window.subviews.first { $0 is EDRHeadroomOverlayView }
        if isShown, existing == nil {
            let overlay = EDRHeadroomOverlayView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -8),
                // 投稿欄とタブバーより上に置く。
                overlay.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -120),
            ])
        } else if !isShown {
            existing?.removeFromSuperview()
        }
    }
}

private final class EDRHeadroomOverlayView: UIView {
    private let label = UILabel()
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = UIColor.black.withAlphaComponent(0.7)
        layer.cornerRadius = 8
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        update()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update() {
        guard let window, let screen = window.windowScene?.screen else { return }
        // あとから足された画面やオーバーレイに隠れないよう、いつも一番上に置き直す。
        window.bringSubviewToFront(self)
        let current = screen.currentEDRHeadroom
        let potential = screen.potentialEDRHeadroom
        // 光の描き方（`ReactionGlowView.render()`）と同じ条件で決める。ダークでは、照らされた側の倍率だけを上げてもHDRで描く。
        let tuning = AppDependencies.tuning
        let isDark = window.traitCollection.userInterfaceStyle == .dark
        let requestsHDR = tuning.value(of: TuningCatalog.reactionGlowHDRExposure) > 1
            || (isDark && tuning.value(of: TuningCatalog.reactionGlowDarkGlowHDRExposure) > 1)
        let glow = potential > 1 && requestsHDR && AppDependencies.settings.drawsReactionGlowInHDR ? "HDR" : "SDR"
        label.text = String(format: "EDRの余地 今 %.2f / 最大 %.2f\n光 %@", current, potential, glow)
    }
}
#endif
