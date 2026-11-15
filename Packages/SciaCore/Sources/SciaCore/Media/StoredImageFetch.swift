public import Foundation
import os

/// 画像を、端末に置いたファイルから読み、なければ取得して置く。カスタム絵文字の画像に使う（docs/image-loading.md）。
/// URLSessionの応答のキャッシュ（URLCache）には頼らない。APIの応答やほかの画像と1つの上限を分け合い、iOS 27のシミュレーターではその上限が10MBで、
/// タイムラインを流すと絵文字の画像が押し出され、表示するたびに取得し直していたため。
public struct StoredImageFetch: Sendable {
    private let files: EmojiImageFiles
    private let fetch: @Sendable (URL) async throws -> Data
    private let logger = SciaLog.logger(category: "emoji")

    public init(files: EmojiImageFiles, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.files = files
        self.fetch = fetch
    }

    public func data(from url: URL) async throws -> Data {
        if let data = await files.data(for: url) {
            ResponseSource.report?(.file)
            return data
        }
        let generation = await files.generation
        let data = try await fetch(url)
        do {
            try await files.store(data, named: url.lastPathComponent, for: url, generation: generation)
        } catch is CancellationError {
            // 取得している間に、使う人がBを消した。置き直さない。
        } catch {
            // 置けなくても、取得した画像は返す。次に読むときに取得し直す。
            logger.error("emoji image store failed: \(SciaLog.describe(error), privacy: .public)")
        }
        return data
    }

    /// 置いたファイルを消す。画像として読めなかったときに呼ぶ。残すと、取得し直さずに読めないファイルを読み続けるため。
    public func discard(_ url: URL) async {
        await files.remove(url)
    }
}
