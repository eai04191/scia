import CryptoKit
import Foundation
import os
import SciaCore

/// 添付ファイルの元のファイルを、合計の大きさに上限のあるディスクキャッシュに置く。共有や保存で縮めずに元の形式のまま渡すためと、
/// ビューアで開き直した画像を通信せずに表示するために使う。
///
/// 画像ライブラリ（Nuke、Kingfisherなど）のディスクキャッシュと同じく、OSが空き容量に応じて消してよい`Caches`に置き、起動をまたいで残す。
/// 合計が上限を超えたら、最後に使った日時の古いものから消す。最後に使った日時は、OSの更新を当てにせず、引くたびにファイルへ書き込む。
///
/// キャッシュのファイルは共有や保存に直接渡さず、`copyForSharing(for:)`で作るコピーを渡す。渡したあとも共有先が読み続けている間に、
/// 整理で消してしまわないようにするため。
///
/// 置く、整理する、引いてコピーするといった操作が重なると、引いたファイルをコピーする前に置き直しや整理で消してしまうため、actorで1つずつ行う。
actor MediaFileCache {
    /// 上限を超えたとき、ここまで減らす割合。整理のたびにすぐまた上限を超えないよう、少し余裕を持たせる（Nukeと同じ値）。
    private static let trimRatio = 0.7

    nonisolated let directory: URL
    /// 共有や保存に渡すコピーを置く場所。
    nonisolated let sharingDirectory: URL
    /// 合計の大きさの上限（バイト）。
    let sizeLimit: Int
    /// 引いたときや置いたときに、最後に使った日時として書く今の日時。
    private let now: @Sendable () -> Date
    private let logger = SciaLog.logger(category: "media")

    /// - Parameters:
    ///   - sharingDirectory: 共有や保存に渡すコピーを置く場所。共有先が読み終えたことを知るすべがないため、作るときに前回の起動で残したコピーを消す。
    ///   - sizeLimit: 合計の大きさの上限（バイト）。既定はNukeのディスクキャッシュの既定値と同じ150MB。
    ///   - now: 最後に使った日時として書く今の日時。テストでは、使った順を実際の時間に頼らずに決めるため、手で進める時計を渡す。
    init(
        directory: URL = .cachesDirectory.appending(path: "MediaFiles"),
        sharingDirectory: URL = .temporaryDirectory.appending(path: "MediaSharing"),
        sizeLimit: Int = 150 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = AppDependencies.now
    ) {
        self.directory = directory
        self.sharingDirectory = sharingDirectory
        self.sizeLimit = sizeLimit
        self.now = now
        try? FileManager.default.removeItem(at: sharingDirectory)
    }

    /// `url`のファイルを置くフォルダ。名前は共有先でファイル名として見えるため、URLごとにフォルダを分け、その中にURLのファイル名のまま置く。
    private func folder(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined(), directoryHint: .isDirectory)
    }

    /// `url`のファイルが置いてあれば、その場所。引いたものは最後に使った日時を更新し、整理で後回しにする。
    func file(for url: URL) -> URL? {
        guard let file = Self.storedFile(in: folder(for: url)) else { return nil }
        touch(file)
        return file
    }

    /// `url`のファイルが置いてあれば、その中身。引いたものは最後に使った日時を更新する。
    func data(for url: URL) -> Data? {
        file(for: url).flatMap { try? Data(contentsOf: $0) }
    }

    /// `url`のファイルが置いてあるか。最後に使った日時は更新しない。
    func contains(_ url: URL) -> Bool {
        Self.storedFile(in: folder(for: url)) != nil
    }

    /// `data`を`url`のファイルとして`name`の名前で置き、置いた場所を返す。同じURLのファイルがあれば置き換える。
    /// 書き込みの途中で落ちても書きかけのファイルを置いたものとして扱わないよう、隠しファイルに書いてから名前を付け替える。
    func store(_ data: Data, named name: String, for url: URL) throws -> URL {
        let folder = folder(for: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: ".partial-\(UUID().uuidString)")
        do {
            try data.write(to: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return try publish(partial, named: name, in: folder)
    }

    /// `source`のファイルを`url`のファイルとして`name`の名前で置き（移す）、置いた場所を返す。大きな動画を一度にメモリへ読み込まないよう、ファイルのまま移す。
    func store(movingFile source: URL, named name: String, for url: URL) throws -> URL {
        let folder = folder(for: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try publish(source, named: name, in: folder)
    }

    /// `url`のファイルが置いてあれば、共有や保存に渡すコピーを作る。引いてからコピーするまでの間に置き直しや整理で消えないよう、1つの操作で行う。
    /// APFSでは中身をコピーせずに複製するため、大きなファイルでもすぐに済み、元が残っている間は場所も取らない。
    func copyForSharing(for url: URL) throws -> URL? {
        guard let file = file(for: url) else { return nil }
        let folder = sharingDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// 合計が上限を超えていたら、最後に使った日時の古いものから、上限の`trimRatio`倍まで消す。
    /// 最後に使ったものは、上限より大きくても消さない。置いた直後や引いた直後のファイルを、渡す前に消さないようにするため。
    /// 書き込みの途中で落ちて、置いたファイルのないフォルダは、上限にかかわらず消す。
    func trim() {
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .totalFileAllocatedSizeKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var entries: [(folder: URL, accessDate: Date, size: Int)] = folders.compactMap { folder in
            guard let file = Self.storedFile(in: folder) else {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (folder, values.contentAccessDate ?? .distantPast, values.totalFileAllocatedSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > sizeLimit else { return }
        entries.sort { $0.accessDate < $1.accessDate }
        let target = Int(Double(sizeLimit) * Self.trimRatio)
        for entry in entries.dropLast() where total > target {
            do {
                try FileManager.default.removeItem(at: entry.folder)
                total -= entry.size
            } catch {
                logger.error("media file cache trim failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.info("media file cache trimmed total=\(total, privacy: .public) limit=\(self.sizeLimit, privacy: .public)")
    }

    /// 書き終えた`source`を、`folder`にあった前のファイルと入れ替えて`name`の名前で置き、整理する。
    private func publish(_ source: URL, named name: String, in folder: URL) throws -> URL {
        for old in Self.storedFiles(in: folder) {
            try? FileManager.default.removeItem(at: old)
        }
        let file = folder.appending(path: name)
        try FileManager.default.moveItem(at: source, to: file)
        touch(file)
        trim()
        return file
    }

    /// フォルダに置いたファイル。書きかけの隠しファイルは数えない。
    private static func storedFiles(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    /// フォルダに置いたファイル。書き込みの途中で落ちるなどしてファイルがなければnil。
    private static func storedFile(in folder: URL) -> URL? {
        storedFiles(in: folder).first
    }

    private func touch(_ file: URL) {
        var values = URLResourceValues()
        values.contentAccessDate = now()
        var file = file
        try? file.setResourceValues(values)
    }
}
