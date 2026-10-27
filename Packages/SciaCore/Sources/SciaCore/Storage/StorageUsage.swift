public import Foundation

/// 端末に置いたファイルの大きさを測り、要らなくなったものを消す。設定のストレージの画面で使う。
///
/// 大きさは、中身の長さではなくディスクに割り当てた大きさ（`totalFileAllocatedSize`）で数える。iPhoneの設定の「iPhoneストレージ」に近い数を出すため。
public enum StorageUsage {
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .addedToDirectoryDateKey, .fileIdentifierKey]

    /// `url`の下にあるファイルの大きさの合計（バイト）。`url`がファイルならその大きさ。なければ0。隠しファイルも数える。
    public static func allocatedSize(of url: URL) -> Int64 {
        total(files(under: url))
    }

    /// `allocatedSize(of:)`と同じだが、`url`がフォルダーで、権限がなく中を読めないときはnil。なければ0。
    /// 読めない中身は列挙で黙って飛ばされ、0と区別できないため、先に中を読めるかを確かめる。
    public static func allocatedSizeIfReadable(of url: URL) -> Int64? {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
        } catch CocoaError.fileReadNoPermission {
            return nil
        } catch {
            // ないか、フォルダーではない。どちらも`allocatedSize(of:)`で測れる。
        }
        return allocatedSize(of: url)
    }

    /// `directory`の下で、`date`より前に置いたファイルの大きさの合計（バイト）。
    public static func allocatedSize(in directory: URL, addedBefore date: Date) -> Int64 {
        total(files(under: directory).filter { $0.added < date })
    }

    /// 同じ中身を指すハードリンクは1つとして数える。アプリ内のSafari（WebKit）のキャッシュは、同じファイルを複数の名前で置くため。
    private static func total(_ files: [Entry]) -> Int64 {
        var seen = Set<UInt64>()
        return files.reduce(0) { sum, file in
            if let identifier = file.identifier, !seen.insert(identifier).inserted {
                return sum
            }
            return sum + file.size
        }
    }

    /// `directory`の下で、`date`より前に置いたファイルを消す。そのあと空になったフォルダーも、`date`より前に置いたものなら消す。`directory`そのものは残す。
    /// 消せないものがあっても残りは消し、最後に失敗を投げる。
    public static func removeItems(in directory: URL, addedBefore date: Date) throws {
        var failure: (any Error)?
        for file in files(under: directory) where file.added < date {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                failure = error
            }
        }
        // 深いフォルダーから順に消し、中のフォルダーが消えたあとで外のフォルダーを消せるようにする。
        // 空のときだけ消せる`rmdir`を使う。空かを確かめてから`removeItem`で消すと、その間に置かれたファイルまで消してしまうため。
        let folders = entries(under: directory)
            .filter { $0.isDirectory && $0.added < date }
            .sorted { $0.url.pathComponents.count > $1.url.pathComponents.count }
        for folder in folders where rmdir(folder.url.path(percentEncoded: false)) != 0 {
            let code = POSIXErrorCode(rawValue: errno)
            guard code != .ENOTEMPTY, code != .ENOENT else { continue }
            failure = POSIXError(code ?? .EIO)
        }
        if let failure { throw failure }
    }

    private struct Entry {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        /// いまのフォルダーに置いた日時。作った日時と違い、コピーしたものや移したものは、そのときの日時になる。
        /// 前の起動のファイルをこの起動でコピーした共有用のコピーや下書きの添付を、前の起動のものと取り違えないため。
        let added: Date
        /// ファイルシステムの中でファイルの中身を指す番号。ハードリンクどうしは同じになる。
        let identifier: UInt64?
    }

    private static func files(under url: URL) -> [Entry] {
        if let root = entry(at: url), !root.isDirectory {
            return [root]
        }
        return entries(under: url).filter { !$0.isDirectory }
    }

    /// `url`の下のファイルとフォルダー。`url`そのものは含めない。シンボリックリンクの先はたどらない。
    private static func entries(under url: URL) -> [Entry] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return [] }
        return enumerator.compactMap { ($0 as? URL).flatMap(entry(at:)) }
    }

    private static func entry(at url: URL) -> Entry? {
        // URLは一度読んだリソースの値を覚えていて、同じURLで読み直すと前の値を返す。消したあとに測り直しても大きさが変わらないため、忘れさせてから読む。
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return Entry(
            url: url,
            isDirectory: values.isDirectory ?? false,
            size: Int64(values.totalFileAllocatedSize ?? 0),
            // 置いた日時を読めないものは、使っているかもしれないので、古いものとして消さない。
            added: values.addedToDirectoryDate ?? .distantFuture,
            identifier: values.fileIdentifier
        )
    }
}
