public import CoreGraphics
public import Foundation

/// 画像のストアが、展開した`CGImage`から、描く側の画像の型を作る方法。iOSでは`UIImage`で作る。
/// メモリの大きさは、作る前の`CGImage`で数える。描く側の画像の型から数えずに済むため。
public struct PlatformImageMaker<Image: Sendable>: Sendable {
    /// 1枚の画像を作る。
    public var still: @Sendable (CGImage) -> Image
    /// コマを均等な間隔で流す、動く画像を作る。`frames`は表示時間に合わせて同じコマを繰り返して並べたもので、`duration`は1周の秒数。作れなければnil。
    public var animated: @Sendable (_ frames: [CGImage], _ duration: TimeInterval) -> Image?

    public init(
        still: @escaping @Sendable (CGImage) -> Image,
        animated: @escaping @Sendable (_ frames: [CGImage], _ duration: TimeInterval) -> Image?
    ) {
        self.still = still
        self.animated = animated
    }

    /// 展開した画像が使うメモリのバイト数。
    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}
