import QuartzCore
import SciaCore
import SwiftUI
import UIKit

extension Benchmark {
    /// SwiftUIのスプリングを`UIView.animate(_:changes:)`に渡した動きと、アプリが動きに使うUIKitのスプリング（`animateSpring`）で、同じ四角を動かす。
    /// 120Hzを頼んだ表示の時計が刻むたびに見えている値を読み、値が何刻みごとに変わったかを数える。
    /// SwiftUIのスプリングはアプリが毎コマ値を入れ、UIKitのスプリングは層のアニメーションなので、読めるのはアプリから見えている値まで。
    /// 描画のプロセスが実際に何Hzで画面に出したかは測れない。
    static let springFrameRate = Benchmark(
        id: "spring-frame-rate",
        title: "スプリングのフレームレート"
    ) { stage in
        var lines: [String] = []
        for motion in FrameRateMotion.all {
            try Task.checkCancellation()
            lines.append("\(motion.name): \(try await motion.measure(in: stage))")
        }
        return lines
    }
}

@MainActor
private struct FrameRateMotion {
    let name: String
    let read: (CALayer) -> CGFloat
    let animate: (UIView) -> Void

    static let all: [FrameRateMotion] = [
        FrameRateMotion(name: "SwiftUIのスプリング 位置", read: \.position.x) { view in
            UIView.animate(.smooth(duration: 1)) { view.center.x += 160 }
        },
        FrameRateMotion(name: "SwiftUIのスプリング 濃さ", read: { CGFloat($0.opacity) }) { view in
            UIView.animate(.smooth(duration: 1)) { view.alpha = 0 }
        },
        FrameRateMotion(name: "SwiftUIのスプリング 大きさ", read: \.bounds.width) { view in
            UIView.animate(.smooth(duration: 1)) { view.bounds.size.width = 160 }
        },
        FrameRateMotion(name: "UIKitのスプリング 位置", read: \.position.x) { view in
            UIView.animateSpring(duration: 1, in: view) { view.center.x += 160 }
        },
        FrameRateMotion(name: "UIKitのスプリング 濃さ", read: { CGFloat($0.opacity) }) { view in
            UIView.animateSpring(duration: 1, in: view) { view.alpha = 0 }
        },
        FrameRateMotion(name: "UIKitのスプリング 大きさ", read: \.bounds.width) { view in
            UIView.animateSpring(duration: 1, in: view) { view.bounds.size.width = 160 }
        },
    ]

    func measure(in stage: UIView) async throws -> String {
        let square = UIView(frame: CGRect(x: 20, y: 50, width: 80, height: 80))
        square.backgroundColor = .systemRed
        stage.addSubview(square)
        defer { square.removeFromSuperview() }
        let sampler = FrameValueSampler { square.layer.presentation().map(read) ?? read(square.layer) }
        sampler.start()
        defer { sampler.stop() }
        try await Task.sleep(for: .milliseconds(300))
        animate(square)
        try await Task.sleep(for: .milliseconds(1400))
        return FrameChangeSummary(samples: sampler.samples)?.text ?? "値が2回以上変わらなかった（刻み=\(sampler.samples.count)）"
    }
}

/// 表示の時計が刻むたびに値を読む。
@MainActor
private final class FrameValueSampler: NSObject {
    private(set) var samples: [FrameChangeSummary.Sample] = []
    private let read: () -> CGFloat
    private var link: CADisplayLink?

    init(read: @escaping () -> CGFloat) {
        self.read = read
    }

    @objc private func step(_ link: CADisplayLink) {
        samples.append(FrameChangeSummary.Sample(time: link.timestamp, value: Double(read())))
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}
