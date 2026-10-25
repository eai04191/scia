import Foundation
import os
import SciaCore
import Synchronization
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
        download: @escaping Download = MediaDownloads.urlSession
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
        let folder = stagingDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
                logger.error("media download failed url=\(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// URLSessionで落とす。共有先でファイル名として見えるため、名前はURLのものを残し、拡張子がなければ応答の形式から付ける。
    nonisolated static let urlSession: Download = { url, folder, onProgress in
        #if DEBUG
        if let delay = DebugFaults.slowDownloadDelay {
            let steps = 20
            for step in 1...steps {
                try await AppDependencies.clock.sleep(for: delay / steps)
                onProgress(Double(step) / Double(steps) * 0.99)
            }
        }
        #endif
        let reporter = ProgressReporter(onProgress: onProgress)
        let (location, response) = try await URLSession.shared.download(from: url, delegate: reporter)
        // エラーの応答でも本文が落ちてくるため、添付ファイルとして残さない。
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: location)
            throw URLError(.badServerResponse)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: fileName(for: url, mimeType: response.mimeType))
        try FileManager.default.moveItem(at: location, to: file)
        return file
    }

    /// 置くファイルの名前。URLの最後の部分を使い、拡張子がなければ`mimeType`から付ける。
    nonisolated static func fileName(for url: URL, mimeType: String?) -> String {
        let name = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "media" : url.lastPathComponent
        guard URL(filePath: name).pathExtension.isEmpty,
              let pathExtension = mimeType.flatMap({ UTType(mimeType: $0) })?.preferredFilenameExtension
        else { return name }
        return "\(name).\(pathExtension)"
    }
}

/// 通信の進み具合を伝える。非同期の`download(from:delegate:)`では書き込みの通知が届かないため、タスクの`progress`を見張る。
private final class ProgressReporter: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let observation = Mutex<NSKeyValueObservation?>(nil)

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let onProgress = onProgress
        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            onProgress(progress.fractionCompleted)
        }
        self.observation.withLock { $0 = observation }
    }
}
