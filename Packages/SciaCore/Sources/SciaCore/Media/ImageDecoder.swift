public import CoreGraphics
public import Foundation
public import ImageIO

/// 画像を、描く大きさまで縮めて展開する。アイコン、添付ファイル、絵文字、投稿欄の手元のファイル、プロフィール画像の切り抜き、送る前の書き出し直しで、同じ読み方をする。
/// 元の大きさのまま展開すると、大きな写真では時間がかかりメモリも食うため、ImageIOの縮めて読む関数で、長い辺が`maxPixelSize`以下になるように読む。
/// 向きは画素に反映し、描くときに展開し直さないよう、ここで展開しておく。重い処理なので、メインスレッドの外で呼ぶ。
public enum ImageDecoder {
    public enum DynamicRange: Sendable {
        /// HDRの画像はゲインマップを使ってHDRのまま展開する。指定しないとSDRに展開され、HDRで描く設定にしても明るくならない。
        /// どれくらいの明るさで描くかは、画面ごとのtraitで決める。
        case high
        /// SDRで展開する。書き出し直して送る画像に使う。
        case standard
    }

    /// `source`の`index`番目のコマを縮めて展開する。読めなければnil。
    public static func thumbnail(of source: CGImageSource, at index: Int = 0, maxPixelSize: Int, dynamicRange: DynamicRange) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if dynamicRange == .high {
            options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        }
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    public static func thumbnail(of data: Data, maxPixelSize: Int, dynamicRange: DynamicRange) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { thumbnail(of: $0, maxPixelSize: maxPixelSize, dynamicRange: dynamicRange) }
    }

    /// 高さを`height`ピクセルにそろえて縮めるときの、長い辺の上限（`maxPixelSize`に渡す値）。行の高さに合わせて描く絵文字に使う。
    /// 長い辺で縮めると、横長の画像は高さが足りずにぼけるため、高さで決める。極端に横長な画像でメモリを使いすぎないよう、幅は高さの`maxAspectRatio`倍で止める。
    /// 大きさを読めなければ`height`を返す。
    public static func maxPixelSize(forHeight height: Int, of data: Data, maxAspectRatio: Double = 8) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, sourceHeight > 0
        else { return height }
        // 5から8の向きは90°回すので、描くときの縦横が入れ替わる。
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            swap(&width, &sourceHeight)
        }
        let aspectRatio = min(max(Double(width) / Double(sourceHeight), 1), maxAspectRatio)
        return Int((Double(height) * aspectRatio).rounded(.up))
    }

    public static func thumbnail(ofFile url: URL, maxPixelSize: Int, dynamicRange: DynamicRange) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { thumbnail(of: $0, maxPixelSize: maxPixelSize, dynamicRange: dynamicRange) }
    }
}
