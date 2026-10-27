#if DEBUG
import Foundation
import os
import SciaCore

/// `scia-debug://storage-probe`。ストレージの画面が測る置き場所を、アプリから読めるかを含めて、アプリのDocuments/AgentDump/storage.txtに書き出す。
/// 実機でアプリ内のSafariのデータ（SystemData）を読めているかを、画面を見ずにdevicectlで取り出して確かめるため。
enum StorageProbe {
    @MainActor
    static func write() {
        let measure = StorageView.Actions.app.measure
        Task {
            let breakdown = await measure()
            let items = breakdown.items.map { "\($0.category): \($0.bytes.map(String.init) ?? "nil") removable=\($0.removableBytes.map(String.init) ?? "nil")" }
            await write(breakdown: items + ["total: \(breakdown.dataBytes) unmeasured=\(breakdown.hasUnmeasuredItems)"])
        }
    }

    @concurrent
    private static func write(breakdown: [String]) async {
        let home = URL.homeDirectory
        var lines = ["== breakdown"] + breakdown + ["home: \(home.path(percentEncoded: false))"]
        lines.append("home total: \(StorageUsage.allocatedSize(of: home))")
        for path in ["", "SystemData", "SystemData/com.apple.SafariViewService"] {
            lines.append(contentsOf: describe(path.isEmpty ? home : home.appending(path: path, directoryHint: .isDirectory), label: path.isEmpty ? "(home)" : path))
        }
        save(lines.joined(separator: "\n") + "\n")
    }

    private static func describe(_ url: URL, label: String) -> [String] {
        var lines = ["== \(label)"]
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            lines.append("contents: \(names.sorted())")
        } catch {
            lines.append("contents error: \(String(describing: error))")
        }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .isReadableKey])
            lines.append("values: isDirectory=\(String(describing: values.isDirectory)) isReadable=\(String(describing: values.isReadable))")
        } catch {
            lines.append("values error: \(String(describing: error))")
        }
        var errors: [String] = []
        var count = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { failed, error in
            errors.append("\(failed.path(percentEncoded: false)): \(String(describing: error))")
            return true
        }) {
            while enumerator.nextObject() != nil { count += 1 }
        } else {
            lines.append("enumerator: nil")
        }
        lines.append("enumerated: \(count) errors: \(errors.prefix(5))")
        lines.append("allocatedSize: \(StorageUsage.allocatedSize(of: url))")
        return lines
    }

    private static func save(_ text: String) {
        do {
            let directory = URL.documentsDirectory.appending(path: "AgentDump")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: directory.appending(path: "storage.txt"), options: .atomic)
        } catch {
            SciaLog.logger(category: "debug").error("storage probe failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
