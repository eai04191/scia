import CCrashMarkTesting
import Foundation
import SciaCore
import SciaTesting
import Testing

/// 子プロセスの中でメインスレッドのクラッシュになるよう、メインスレッドからforkする。
@MainActor @Suite(.scratch) struct CrashMarkTests {
    private func record(after kind: ccm_crash_kind, item: String = "12345") -> (signal: Int32, record: CrashMark.Record?) {
        let file = TestScratch.url("crash-mark")
        let signal = file.withUnsafeFileSystemRepresentation { path in
            ccm_testing_crash_child(path, "https://example.com/#1", item, kind)
        }
        return (signal, CrashMark.takeRecord(fileAt: file))
    }

    @Test(arguments: [CCM_CRASH_ABORT, CCM_CRASH_BAD_ACCESS, CCM_CRASH_TRAP, CCM_CRASH_STACK_OVERFLOW])
    func メインスレッドのクラッシュでは処理中の項目が残る(kind: ccm_crash_kind) {
        let result = record(after: kind)
        #expect(result.signal != 0)
        #expect(result.record == CrashMark.Record(accountID: "https://example.com/#1", itemID: "12345"))
    }

    @Test func 投げ直すのでプロセスは元のシグナルで死ぬ() {
        #expect(record(after: CCM_CRASH_ABORT).signal == SIGABRT)
    }

    @Test func 記録は一度読むと消える() {
        let file = TestScratch.url("crash-mark")
        _ = file.withUnsafeFileSystemRepresentation { ccm_testing_crash_child($0, "account", "1", CCM_CRASH_ABORT) }
        #expect(CrashMark.takeRecord(fileAt: file) != nil)
        #expect(CrashMark.takeRecord(fileAt: file) == nil)
    }

    @Test func ほかのスレッドのクラッシュは記録しない() {
        #expect(record(after: CCM_CRASH_ABORT_OFF_MAIN).record == nil)
    }

    @Test func 項目を消したあとのクラッシュは記録しない() {
        #expect(record(after: CCM_CRASH_ABORT_AFTER_CLEAR).record == nil)
    }

    @Test func ハンドラーが動かない終了は記録しない() {
        #expect(record(after: CCM_CRASH_KILLED).record == nil)
    }

    @Test func 長すぎる項目は記録しない() {
        #expect(record(after: CCM_CRASH_ABORT, item: String(repeating: "1", count: 129)).record == nil)
    }

    @Test func ファイルがなければ記録もない() {
        #expect(CrashMark.takeRecord(fileAt: TestScratch.url("missing")) == nil)
    }
}
