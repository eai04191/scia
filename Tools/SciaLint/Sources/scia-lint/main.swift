import Foundation
import SciaLintRules
import Synchronization

// 使い方: scia-lint <リポジトリのルート>
// 違反を`パス:行:列: error: 文言 (規則)`の形で出し、1つでもあれば1で終わる
let root = URL(filePath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath).standardizedFileURL
let directories = ["App", "ShareExtension", "Packages/SciaCore/Sources"]

// 読めないフォルダーがあると、そこのファイルを調べないまま通ってしまうので、失敗させる
var paths: [String] = []
var unreadable: [String] = []
for directory in directories {
    let url = root.appending(path: directory)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
          let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { file, error in
              unreadable.append("error: \(file.path)を読めない: \(error)")
              return true
          }) else {
        unreadable.append("error: \(url.path)を読めない")
        continue
    }
    for case let file as URL in enumerator where file.pathExtension == "swift" {
        paths.append(String(file.standardizedFileURL.path.dropFirst(root.path.count + 1)))
    }
}
guard unreadable.isEmpty else {
    FileHandle.standardError.write(Data((unreadable.joined(separator: "\n") + "\n").utf8))
    exit(2)
}
paths = paths.filter { path in Linter.rules.contains { $0.appliesTo(path) } }.sorted()

// SwiftPMが使うビルド済みのswift-syntaxは、パーサーが遅く、1つずつ読むと全体で10秒かかるので、ファイルごとに並べて調べる
let reports = Mutex([String?](repeating: nil, count: paths.count))
let failures = Mutex([String]())
DispatchQueue.concurrentPerform(iterations: paths.count) { index in
    let path = paths[index]
    let url = root.appending(path: path)
    do {
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = Linter.lint(source: source, path: path).map { violation in
            "\(url.path):\(violation.line):\(violation.column): error: \(violation.message) (\(violation.rule))"
        }
        reports.withLock { $0[index] = lines.joined(separator: "\n") }
    } catch {
        failures.withLock { $0.append("error: \(url.path)を読めない: \(error)") }
    }
}

let failed = failures.withLock { $0 }
for failure in failed {
    FileHandle.standardError.write(Data((failure + "\n").utf8))
}
let output = reports.withLock { $0.compactMap { $0 }.filter { !$0.isEmpty } }
for report in output {
    print(report)
}
exit(!failed.isEmpty ? 2 : output.isEmpty ? 0 : 1)
