public import Foundation

/// 共有拡張が受け取ったメディアを、アプリの投稿欄へ渡すためのフォルダー。拡張とアプリが両方読めるApp Groupのコンテナに置く。
/// 1回の共有ごとにIDのフォルダーを作り、その中に受け取った順の番号のフォルダーを作って、ファイルを元の名前のまま置く。
/// 名前を残すのは、アプリが拡張子から形式を決め、その名前でサーバーに送るため。番号で分けるのは、同じ名前のファイルが届いても並びを保つため。
public struct SharedMediaInbox: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// App Groupのコンテナの中に置く。コンテナを使えない（App Groupの権限がない）ときはnil。
    public init?(appGroup: String) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        root = container.appending(path: "SharedMedia", directoryHint: .isDirectory)
    }

    /// 受け取ったファイルを、`id`の共有の`index`番目としてコピーする。
    public func store(_ file: URL, id: UUID, index: Int) throws {
        let folder = folder(of: id).appending(path: String(index), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try excludeRootFromBackup()
        try FileManager.default.copyItem(at: file, to: folder.appending(path: file.lastPathComponent))
    }

    /// `id`の共有のファイルを、受け取った順に返す。
    public func files(id: UUID) throws -> [URL] {
        let fileManager = FileManager.default
        return try fileManager.contentsOfDirectory(at: folder(of: id), includingPropertiesForKeys: nil)
            .compactMap { folder in Int(folder.lastPathComponent).map { (index: $0, folder: folder) } }
            .sorted { $0.index < $1.index }
            .flatMap { try fileManager.contentsOfDirectory(at: $0.folder, includingPropertiesForKeys: nil) }
    }

    /// `id`の共有のファイルを消す。投稿欄の一時ディレクトリへコピーし終えたときと、受け取らなかったときに呼ぶ。
    /// 受け取ってから`maximumAge`より経った共有を消す。アプリは共有を開かれたときにすぐ受け取って消すので、残っているのは、
    /// 拡張が途中で終わったりアプリが開かれなかったりして、受け取られないままになったもの。アプリを起動したときに呼ぶ。
    public func removeStale(now: Date, maximumAge: TimeInterval = 24 * 60 * 60) {
        let fileManager = FileManager.default
        guard let shares = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for share in shares {
            guard let modified = try? share.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > maximumAge
            else { continue }
            try? fileManager.removeItem(at: share)
        }
    }

    public func remove(id: UUID) {
        try? FileManager.default.removeItem(at: folder(of: id))
    }

    /// 受け渡しの途中のファイルは、端末のバックアップに入れない。App Groupのコンテナは、Cachesでない場所はバックアップに入るため。
    private func excludeRootFromBackup() throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = root
        try root.setResourceValues(values)
    }

    private func folder(of id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
}
