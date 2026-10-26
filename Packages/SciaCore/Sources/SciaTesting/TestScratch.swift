public import Foundation
public import Testing
import Synchronization

/// テストの間だけ使う一時ファイルと設定の保存先。`.scratch`を付けたテストが終わったら消す。
///
/// テストは毎回違う名前で作るため、消さないと走らせるたびに溜まる。アプリのテストはアプリと同じコンテナを使うので、端末のtmpと
/// Library/Preferencesに、SciaCoreのテストはMacのユーザーのtmpとLibrary/Preferencesに、何万も残っていた。
///
/// テストの終わりに消しても、消し切れないものがある。設定は、iOSのシミュレーターでは消す前に書き出させても、少しあとに書き出しが届いてplistが戻った。
/// 一時ファイルも、テストのあとに裏で動き続けた処理が、消したあとに作り直すことがある。そのため名前にプロセスIDを入れ、
/// そのプロセスで最初に`.scratch`のテストを始める前に、終わったプロセスが残したものを消す。残るのは、直前に走らせた分のうち消し切れなかったものだけになる。
/// 走っているプロセスのものは消さない。Macでは、ほかのworktreeで同時に走っているテストと、tmpとLibrary/Preferencesを共有するため。
public enum TestScratch {
    @TaskLocal static var registry: Registry?

    static let prefix = "TestScratch"

    /// 一時フォルダーの中の、`name`で始まる名前の場所。ファイルにもフォルダーにも使える。作るのは使う側で行う。
    /// - Parameter pathExtension: ファイルの拡張子。形式を拡張子から決める処理に渡すときに付ける。
    public static func url(_ name: String, pathExtension: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) -> URL {
        let fileName = "\(prefix)-\(getpid())-\(name)-\(UUID().uuidString)" + (pathExtension.map { ".\($0)" } ?? "")
        let url = URL.temporaryDirectory.appending(path: fileName)
        register(.item(url), sourceLocation: sourceLocation)
        return url
    }

    /// `name`で始まる名前の、空の設定の保存先。
    public static func defaults(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) -> UserDefaults {
        let suite = suiteName(name, sourceLocation: sourceLocation)
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("テスト用の設定の保存先を作れませんでした")
        }
        return defaults
    }

    /// `name`で始まる、設定の保存先の名前。保存先の中身を名前で読むテスト（`persistentDomain(forName:)`）が使う。
    public static func suiteName(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        let suite = "\(prefix).\(getpid()).\(name).\(UUID().uuidString)"
        register(.defaults(suite), sourceLocation: sourceLocation)
        return suite
    }

    /// `.scratch`の外で作ったときは、消せないまま残るので、テストを失敗にする。テストの実行ごと止めると、ほかのテストの結果まで見えなくなるため、止めはしない。
    private static func register(_ item: Item, sourceLocation: SourceLocation) {
        guard let registry else {
            Issue.record("TestScratchを使うテストには、テストかスイートに`.scratch`を付ける", sourceLocation: sourceLocation)
            return
        }
        registry.add(item)
    }

    /// 終わったプロセスが残した一時ファイルと設定の保存先を消す。プロセスごとに一度だけ、最初の`.scratch`のテストを始める前に行う。
    static let leftoversRemoved: Void = {
        removeLeftovers(in: URL.temporaryDirectory, separator: "-", suffix: "")
        removeLeftovers(in: URL.libraryDirectory.appending(path: "Preferences"), separator: ".", suffix: ".plist")
    }()

    static func removeLeftovers(in folder: URL, separator: String, suffix: String) {
        let head = prefix + separator
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        for name in names where name.hasPrefix(head) && name.hasSuffix(suffix) {
            guard let pid = Int32(name.dropFirst(head.count).prefix { $0 != Character(separator) }), !isRunning(pid) else { continue }
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// `pid`のプロセスが走っているか。ほかのアプリのプロセスに送る権限がなく`EPERM`になるときも、走っている。
    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    enum Item {
        case item(URL)
        case defaults(String)
    }

    final class Registry: Sendable {
        private let items = Mutex<[Item]>([])

        func add(_ item: Item) {
            items.withLock { $0.append(item) }
        }

        /// 作ったものを消す。設定は、まだファイルに書き出していない値を書き出させてから、plistのファイルを消す。
        /// 書き出す前に消すと、あとでまとめて書き出したときにplistが戻る（iOSのシミュレーターでは、10秒おきにまとめて書き出して戻った）。
        /// 値を消す`removePersistentDomain`は呼ばない。呼ぶと、あとから空のplistが書き戻された（macOSで、プロセスが終わるときに戻るのを確かめた）。
        func removeAll() {
            let items = items.withLock { $0 }
            for item in items {
                switch item {
                case .item(let url):
                    try? FileManager.default.removeItem(at: url)
                case .defaults(let suite):
                    CFPreferencesAppSynchronize(suite as CFString)
                    let plist = URL.libraryDirectory.appending(path: "Preferences/\(suite).plist")
                    try? FileManager.default.removeItem(at: plist)
                }
            }
        }
    }
}

/// テストが終わったら、テストの中で`TestScratch`で作ったものを消すトレイト。スイートに付けると、その中のテストごとに消す。
public struct TestScratchTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        TestScratch.leftoversRemoved
        let registry = TestScratch.Registry()
        defer { registry.removeAll() }
        try await TestScratch.$registry.withValue(registry) {
            try await function()
        }
    }
}

extension Trait where Self == TestScratchTrait {
    /// テストが終わったら、`TestScratch`で作った一時ファイルと設定の保存先を消す。
    public static var scratch: Self { TestScratchTrait() }
}
