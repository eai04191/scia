public import Foundation
import AVFoundation

/// 送る動画から音声を除く。Mastodonは音声のない動画をGIF（`gifv`）として扱うので、GIFとして送るときに使う。
public enum AudioRemover {
    /// 映像は作り直さずに、映像のトラックだけを組み直して`destination`に書き出す。
    ///
    /// 組み直すとメタデータは付いてこないので、位置情報も一緒に除かれる。
    @concurrent
    public static func removingAudio(fromVideo url: URL, destination: URL) async throws {
        // トラックは元のアセットを弱く持つので、書き出し終えるまでアセットを持っておく。
        let asset = AVURLAsset(url: url)
        try await LocationRemover.recomposing(try await asset.load(.tracks), of: [.video], to: destination)
        withExtendedLifetime(asset) {}
    }
}
