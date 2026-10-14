import Foundation
import os
import SciaCore
import Synchronization
import UniformTypeIdentifiers

/// 動画、GIF、音声の添付ファイルを、共有や保存のために端末へ落とす。
///
/// 画像と違って再生はURLから直接行い、ファイルを手元に持たないため、共有や保存を求められたときに落とす。
/// 落としたファイルは起動している間残し、同じ添付ファイルをまた共有するときに使う。
@MainActor
final class MediaDownloads {
    /// `url`のファイルを`directory`の中へ落とし、置いた場所を返す。`onProgress`には0から1の進み具合を渡す。
    /// 呼び出し側のタスクを取り消したら、通信も止める。
    typealias Download = @Sendable (_ url: URL, _ directory: URL, _ onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL

    private let directory: URL
    private let download: Download
    /// 落とし終えたURLごとの、手元のファイル。
    private var files: [URL: URL] = [:]
    private let logger = SciaLog.logger(category: "media")

    /// - Parameter directory: 落としたファイルを置く場所。前回の起動で残したファイルを消すため、作るときに中身を空にする。
    init(directory: URL = .temporaryDirectory.appending(path: "MediaDownloads"), download: @escaping Download = MediaDownloads.urlSession) {
        self.directory = directory
        self.download = download
        try? FileManager.default.removeItem(at: directory)
    }

    /// 落とし終えていれば、手元のファイル。
    func cachedFile(for url: URL) -> URL? {
        files[url]
    }

    /// `url`のファイルを落とす。落とし終えていれば、落とさずにそのファイルを返す。
    /// - Parameter onProgress: 進み具合を0から1で、メインアクターで受け取る。
    func file(for url: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        if let file = files[url] {
            return file
        }
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            let file = try await download(url, folder) { fraction in
                Task { @MainActor in onProgress(fraction) }
            }
            files[url] = file
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if !Task.isCancelled {
                logger.error("media download failed url=\(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// URLSessionで落とす。共有先でファイル名として見えるため、名前はURLのものを残し、拡張子がなければ応答の形式から付ける。
    nonisolated static let urlSession: Download = { url, folder, onProgress in
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
