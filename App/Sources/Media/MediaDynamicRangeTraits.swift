import AVKit
import QuartzCore
import SciaCore
import UIKit

/// 設定のHDRの明るさを、画像を描く明るさの幅（trait）に効かせる。
/// `UIImageView`は、個別に明るさの幅を指定しなければ、traitの`imageDynamicRange`に従って描く。動画は`PlayerPageController`がtraitを読んで当てる。
@MainActor
enum MediaDynamicRangeTraits {
    /// `value`で選んだ設定を、`target`と一緒に`apply`に渡す。選び直すと渡し直すので、開いている画面にもすぐ効く。
    /// `target`は弱く持ち、なくなったら渡し直すのをやめる。ビューアは開くたびに作り直すため、閉じたあとに見張りを残さない。
    static func follow<Target: AnyObject & Sendable>(
        _ target: Target,
        settings: AppSettings,
        _ value: @escaping @MainActor (AppSettings) -> MediaDynamicRange,
        apply: @escaping @MainActor (Target, UIImage.DynamicRange) -> Void
    ) {
        withObservationTracking {
            apply(target, UIImage.DynamicRange(value(settings)))
        } onChange: { [weak target] in
            Task { @MainActor in
                guard let target else { return }
                follow(target, settings: settings, value, apply: apply)
            }
        }
    }
}

extension UIImage.DynamicRange {
    init(_ range: MediaDynamicRange) {
        switch range {
        case .standard: self = .standard
        case .constrainedHigh: self = .constrainedHigh
        case .high: self = .high
        }
    }
}

extension CALayer.DynamicRange {
    /// 画像を描く明るさの幅を、レイヤーの明るさの幅にする。指定がなければシステムに任せる。
    init(_ range: UIImage.DynamicRange) {
        switch range {
        case .standard: self = .standard
        case .constrainedHigh: self = .constrainedHigh
        case .high: self = .high
        default: self = .automatic
        }
    }
}

extension AVDisplayDynamicRange {
    /// 画像を描く明るさの幅を、`AVPlayerViewController`の明るさの幅にする。指定がなければシステムに任せる。
    init(_ range: UIImage.DynamicRange) {
        switch range {
        case .standard: self = .standard
        case .constrainedHigh: self = .constrainedHigh
        case .high: self = .high
        default: self = .automatic
        }
    }
}
