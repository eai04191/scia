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
            Task(.withoutRequests) { @MainActor in
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

/// 設定で選んだメディアの明るさの幅。窓とビューアに載せ、`DynamicRangeFollowingImageView`が読む。
/// システムの`imageDynamicRange`だけでは、`UICollectionView`の中に届かない。コレクションビューは窓の値を受け継がず、システムの既定の値（実機では控えめなHDR）を使うため（シミュレーターで確かめた）。
struct MediaDynamicRangeTrait: UITraitDefinition {
    static let defaultValue = UIImage.DynamicRange.unspecified
}

extension UITraitCollection {
    var mediaDynamicRange: UIImage.DynamicRange { self[MediaDynamicRangeTrait.self] }
}

extension UIMutableTraits {
    var mediaDynamicRange: UIImage.DynamicRange {
        get { self[MediaDynamicRangeTrait.self] }
        set { self[MediaDynamicRangeTrait.self] = newValue }
    }
}

/// 設定で選んだメディアの明るさの幅（`MediaDynamicRangeTrait`）を、画像ビュー自身の明るさの幅として指定し続ける`UIImageView`。
/// 指定は画像を置いたあとに変えても効く（実機で、画像ビューに直接指定すると画面の余地が上がった）。
final class DynamicRangeFollowingImageView: UIImageView {
    init() {
        super.init(frame: .zero)
        registerForTraitChanges([MediaDynamicRangeTrait.self]) { (self: Self, _) in
            self.applyDynamicRange()
        }
    }

    // 外で組んだタイルをタイムラインの行に入れたときは、traitの変化が知らされない（AppTestsで確かめた）ため、窓に入ったときにも指定する。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDynamicRange()
    }

    private func applyDynamicRange() {
        preferredImageDynamicRange = traitCollection.mediaDynamicRange
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
