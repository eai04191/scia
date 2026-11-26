import SciaCore
import UIKit

/// 開発用。画面がSDRの白の何倍まで明るく描けるか（今の余地と最大の余地）と、お気に入りとブーストの光をHDRとSDRのどちらで描くかを、画面の隅に出し続ける。
/// 今の余地は画面の明るさや周りの明るさで変わるが、変わったことを知らせる通知がないため、出している間は一定の間隔で再読み込みする。
/// 晴れた屋外などで、余地がどこまで下がるか、HDRの内容がないと1に戻るかを、実機で確かめるために使う。
@MainActor
enum EDRHeadroomOverlay {
    /// デバッグメニューの項目に合わせて、`window`に出したり消したりする。
    static func follow(_ window: UIWindow, developerMode: DeveloperMode) {
        withObservationTracking {
            apply(developerMode.showsEDRHeadroom, to: window)
        } onChange: { [weak window] in
            Task { @MainActor in
                guard let window else { return }
                follow(window, developerMode: developerMode)
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
                overlay.leadingAnchor.constraint(greaterThanOrEqualTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 8),
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
        let glow = ReactionGlowView.mayDrawInHDR && potential > 1 && requestsHDR && AppDependencies.settings.appearance.drawsReactionGlowInHDR ? "HDR" : "SDR"
        let settings = window.traitCollection.appSettings
        let windowRange = "窓の設定 \(settings.store.library.name(of: settings.presetID) ?? "-")・一覧 \(settings.mediaDynamicRange.rawValue)・窓のtrait \(Self.name(of: window.traitCollection.imageDynamicRange))"
        label.text = ([String(format: "EDRの余地 今 %.2f / 最大 %.2f\n光 %@", current, potential, glow), windowRange] + Self.hdrDrawers(in: window)).joined(separator: "\n")
    }

    /// ウィンドウの中でHDRで描きうるものを、種類ごとに数えて並べる。余地を上げているものを探すため。
    /// HDRの画像を出している画像ビュー（実際の明るさの幅と画像ビューの指定）と、HDRを指定したレイヤーを数える。隠れているものと透明なものは数えない。
    private static func hdrDrawers(in window: UIWindow) -> [String] {
        var counts: [String: Int] = [:]
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0, !(view is EDRHeadroomOverlayView) else { return }
            if let imageView = view as? UIImageView, imageView.image?.isHighDynamicRange == true {
                let key = "HDRの画像 \(type(of: imageView)) trait \(name(of: imageView.traitCollection.imageDynamicRange))・設定のtrait \(name(of: imageView.traitCollection.mediaDynamicRange))・指定 \(name(of: imageView.preferredImageDynamicRange))\(boundary(above: imageView))"
                counts[key, default: 0] += 1
            }
            visitLayers(view.layer, owner: view)
            view.subviews.forEach(visit)
        }
        func visitLayers(_ layer: CALayer, owner: UIView) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            if layer.preferredDynamicRange == .high || layer.preferredDynamicRange == .constrainedHigh || layer.contentsHeadroom > 1 {
                let key = "HDRのレイヤー \(type(of: layer)) in \(type(of: owner))"
                counts[key, default: 0] += 1
            }
            // サブビューのレイヤーは、そのビューを見るときに数える。
            for sublayer in layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
                visitLayers(sublayer, owner: owner)
            }
        }
        visit(window)
        return counts.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }
    }

    /// `view`から親をたどり、明るさの幅が親と違う最初のビューを返す。ウィンドウの値が途中で上書きされている場所を探すため。
    private static func boundary(above view: UIView) -> String {
        var current = view
        while let parent = current.superview {
            if parent.traitCollection.imageDynamicRange != current.traitCollection.imageDynamicRange {
                return "\n  境目: \(type(of: current))（\(name(of: current.traitCollection.imageDynamicRange))）の親 \(type(of: parent))（\(name(of: parent.traitCollection.imageDynamicRange))）"
            }
            current = parent
        }
        return ""
    }

    private static func name(of range: UIImage.DynamicRange) -> String {
        switch range {
        case .standard: "SDR"
        case .constrainedHigh: "控えめなHDR"
        case .high: "HDR"
        default: "未指定"
        }
    }
}
