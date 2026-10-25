import Foundation
import os
import SciaCore
import UniformTypeIdentifiers

/// 添付ファイルの元のファイルを、共有や保存に渡せるようにする。ディスクキャッシュになければ落として置く。
///
/// 動画、GIF、音声は再生をURLから直接行い、ファイルを手元に持たないため、共有や保存を求められたときに落とす。
/// 画像は表示のために読み込んだ元のファイルがキャッシュにあるが、整理で消えていたら同じように落とし直す。
@MainActor
final class MediaDownloads {
    /// `url`のファイルを`directory`の中へ落とし、置いた場所を返す。`onProgress`には0から1の進み具合を渡す。
    /// 呼び出し側のタスクを取り消したら、通信も止める。
    typealias Download = @Sendable (_ url: URL, _ directory: URL, _ onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL

    private let files: MediaFileCache
    /// 落としている途中のファイルを置く場所。落とし終えたらキャッシュへ移す。
    private let stagingDirectory: URL
    private let download: Download
    private let logger = SciaLog.logger(category: "media")

    /// - Parameter stagingDirectory: 落としている途中のファイルを置く場所。前回の起動で落とし損ねたものを消すため、作るときに中身を空にする。
    init(
        files: MediaFileCache,
        stagingDirectory: URL = .temporaryDirectory.appending(path: "MediaDownloads"),
        download: @escaping Download = MediaDownloads.network
    ) {
        self.files = files
        self.stagingDirectory = stagingDirectory
        self.download = download
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    /// `url`のファイルの、共有や保存に渡すコピーを返す。キャッシュになければ落として置いてからコピーする。
    /// - Parameter onProgress: 落とし始めたら0を、そのあと進み具合を0から1で、メインアクターで受け取る。キャッシュにあれば呼ばない。
    func fileForSharing(for url: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        if let copy = try await files.copyForSharing(for: url) {
            return copy
        }
        try Task.checkCancellation()
        let generation = await files.generation
        onProgress(0)
        let folder = stagingDirectory.appending(fileName: SafeFileName(UUID().uuidString), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let downloaded = try await download(url, folder) { fraction in
                Task { @MainActor in onProgress(fraction) }
            }
            let name = await MediaImageStore.originalFileName(ofFileAt: downloaded, for: url) ?? downloaded.lastPathComponent
            _ = try await files.store(movingFile: downloaded, named: name, for: url, generation: generation)
            // 置いたものは最後に使ったものとして整理で残るため、ここで見つからないのは置いた直後に消された異常な場合だけ。
            guard let copy = try await files.copyForSharing(for: url) else { throw CocoaError(.fileNoSuchFile) }
            return copy
        } catch {
            if !Task.isCancelled {
                logger.error("media download failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
            }
            throw error
        }
    }

    /// 通信の入口（`HTTPClient`）で落とす。共有先でファイル名として見えるため、名前はURLのものを残し、拡張子がなければ応答の形式から付ける。
    /// 使う人が押した操作なので、自動の通信が止められている間も送る。2xx以外の応答は、本文を添付ファイルとして残さずに`HTTPStatusError`で失敗させる。
    nonisolated static let network: Download = { url, folder, onProgress in
        #if DEBUG
        if let delay = DebugFaults.slowDownloadDelay {
            let steps = 20
            for step in 1...steps {
                try await AppDependencies.clock.sleep(for: delay / steps)
                onProgress(Double(step) / Double(steps) * 0.99)
            }
        }
        #endif
        let (location, response) = try await AppDependencies.http.download(URLRequest(url: url), limit: ResponseLimit.download, scope: .host, progress: onProgress)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(fileName: SafeFileName(fileName(for: url, mimeType: response.mimeType), fallback: "media"))
        try FileManager.default.moveItem(at: location, to: file)
        return file
    }

    /// 置くファイルの名前。URLの最後の部分を使い、拡張子がなければ`mimeType`から付ける。
    /// URLの最後の部分はサーバーが決め、`%2F`で区切りを入れられるため、`SafeFileName`で落とすフォルダーの直下に収める。
    nonisolated static func fileName(for url: URL, mimeType: String?) -> String {
        let name = SafeFileName(url.lastPathComponent, fallback: "media").value
        guard URL(filePath: name).pathExtension.isEmpty,
              let pathExtension = mimeType.flatMap({ UTType(mimeType: $0) })?.preferredFilenameExtension
        else { return name }
        return "\(name).\(pathExtension)"
    }
}
