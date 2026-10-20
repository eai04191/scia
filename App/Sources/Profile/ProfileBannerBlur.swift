import CoreImage
import SciaCore
import UIKit

/// プロフィールのヘッダー画像から作る、ぼかした画像。画像の上を画面の上端まで伸ばす部分と、ビューアで開いている間に画像のあった場所を埋める覆いに使う。
///
/// 伸ばす部分は、画像を上端で折り返してぼかしたもので埋める。2つは、画像と折り返した画像をつなげた1枚をぼかしてから切り分ける。
/// 別々にぼかすと、境目で色と模様が揃わないため。`UIBackgroundExtensionView`を使わないのも同じ理由で、
/// 部品の中のぼかしを覆いに合わせられず、中身を覆いに変えると描き直しが遅れて、ビューアを閉じ終わるときに帯が灰色になった。
struct ProfileBannerBlur {
    /// 画像のあった場所を埋める、ぼかした画像。枠と同じ縦横比。
    let cover: UIImage
    /// 画像の上に伸ばす、折り返してぼかした画像。下端が画像の上端につながる。高さは枠の`reflectionHeightRatio`倍。
    /// 画像の上端の近くは弱くぼかし、離れるほど強くする。折り返した画像なので、上端の近くはくっきりした画像となめらかにつながる。
    let reflection: UIImage
    /// どこも同じ強さでぼかした、伸ばす部分の画像。覆いを出している間に使う。上端の近くまで強くぼけた覆いと、境目でつながる。
    let uniformReflection: UIImage

    /// 伸ばす部分の画像の高さの、枠の高さに対する倍率。引っぱってこれより高く伸ばした分は、何も描かない。
    static let reflectionHeightRatio: CGFloat = 4

    struct Style: Equatable {
        /// ぼかしの強さ（pt）。
        var blur: CGFloat
        /// 暗くする割合。0なら暗くしない。
        var dim: CGFloat
        /// 画像の上端から、ぼかしが最も強くなるまでの長さ（pt）。0なら上端から同じ強さでぼかす。
        var seam: CGFloat
    }

    /// ぼかす前に縮めたときの、1ピクセルにあたる長さ（pt）。上端から離れた部分は強くぼかすので、縮めても見た目は変わらず、軽く作れる。
    /// 上端の近くは弱くぼかすため粗さが残る。2ptなら、3倍の画面で1ピクセルを6×6の画素に整数倍で引き伸ばして描ける。
    /// 画面の画素数のまま作って比べても、上端の近くの見た目の違いは小さかった。
    private static let pointsPerPixel: CGFloat = 2
    @MainActor private static let context = CIContext()

    /// - Parameters:
    ///   - frameWidth: 画像を置く枠の幅（pt）。
    ///   - frameAspect: 画像を置く枠の縦横比（高さ÷幅）。枠に見えている範囲だけを使う。
    @MainActor
    static func make(from image: CGImage, frameWidth: CGFloat, frameAspect: CGFloat, style: Style) -> ProfileBannerBlur? {
        let workingWidth = max((frameWidth / pointsPerPixel).rounded(), 1)
        let imageSize = CGSize(width: image.width, height: image.height)
        let visible = ProfileBannerLayout.visibleRect(ofImageSized: imageSize, inFrameWithAspect: frameAspect)
        guard !visible.isEmpty else { return nil }
        // Core Imageの座標は左下が原点のため、上下を直す。
        // 切り出す範囲と縮めたあとの大きさは、画素の境目に揃える。半端な行は半透明になり、元の画像と折り返した画像の境目に、下の背景が線になって透けるため。
        let source = CGRect(x: visible.minX, y: imageSize.height - visible.maxY, width: visible.width, height: visible.height)
            .integral
            .intersection(CGRect(origin: .zero, size: imageSize))
        let height = max((workingWidth * frameAspect).rounded(), 1)
        let base = CIImage(cgImage: image)
            .cropped(to: source)
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: workingWidth / source.width, y: height / source.height))
        // 上端で折り返した画像を、元の画像の上につなげる。
        let mirrored = base
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: height * 2))
        let joined = mirrored.composited(over: base).clampedToExtent()
        let pixelsPerPoint = workingWidth / frameWidth
        // 一様なぼかしも同じフィルターで作り、上端から離れた部分の見た目を2つで揃える。
        let full = CIImage(color: .white)
        let ramp = max(style.seam * pixelsPerPoint, 0.001)
        let seamMask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: height),
            "inputColor0": CIColor.black,
            "inputPoint1": CIVector(x: 0, y: height + ramp),
            "inputColor1": CIColor.white,
        ])?.outputImage ?? full
        let blur = { (mask: CIImage) in
            dimmed(joined.applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": mask,
                "inputRadius": style.blur * pixelsPerPoint,
            ]), by: style.dim)
        }
        let uniform = blur(full)
        let seamed = blur(seamMask)
        let coverRect = CGRect(x: 0, y: 0, width: workingWidth, height: height)
        let reflectionRect = CGRect(x: 0, y: height, width: workingWidth, height: height * reflectionHeightRatio)
        guard let cover = context.createCGImage(uniform, from: coverRect),
              let reflection = context.createCGImage(seamed, from: reflectionRect),
              let uniformReflection = context.createCGImage(uniform, from: reflectionRect)
        else { return nil }
        return ProfileBannerBlur(
            cover: UIImage(cgImage: cover),
            reflection: UIImage(cgImage: reflection),
            uniformReflection: UIImage(cgImage: uniformReflection)
        )
    }

    private static func dimmed(_ image: CIImage, by dim: CGFloat) -> CIImage {
        guard dim > 0 else { return image }
        let keep = 1 - dim
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
        ])
    }
}
