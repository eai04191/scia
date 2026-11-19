import CCrashMarkTesting
import Foundation
import SciaCore
import SciaTesting
import Testing

/// 子プロセスの中でメインスレッドのクラッシュになるよう、メインスレッドからforkする。
/// 子プロセスが終わるのはメインスレッドで待たない。子プロセスが終わらないと、メインスレッドで動くほかのテストまで止まるため。
@MainActor @Suite(.scratch) struct CrashMarkTests {
    private func record(after kind: ccm_crash_kind, item: String = "12345") async throws -> (signal: Int32, record: CrashMark.Record?) {
        let file = TestScratch.url("crash-mark")
        let signal = try await CrashChild.run(file: file, account: "https://example.com/#1", item: item, kind: kind)
        return (signal, CrashMark.takeRecord(fileAt: file))
    }

    @Test(arguments: [CCM_CRASH_ABORT, CCM_CRASH_BAD_ACCESS, CCM_CRASH_TRAP, CCM_CRASH_STACK_OVERFLOW])
    func メインスレッドのクラッシュでは処理中の項目が残る(kind: ccm_crash_kind) async throws {
        let result = try await record(after: kind)
        #expect(result.signal != 0)
        #expect(result.record == CrashMark.Record(accountID: "https://example.com/#1", itemID: "12345"))
    }

    @Test func 投げ直すのでプロセスは元のシグナルで死ぬ() async throws {
        #expect(try await record(after: CCM_CRASH_ABORT).signal == SIGABRT)
    }

    @Test func 記録は一度読むと消える() async throws {
        let file = TestScratch.url("crash-mark")
        _ = try await CrashChild.run(file: file, account: "account", item: "1", kind: CCM_CRASH_ABORT)
        #expect(CrashMark.takeRecord(fileAt: file) != nil)
        #expect(CrashMark.takeRecord(fileAt: file) == nil)
    }

    @Test func ほかのスレッドのクラッシュは記録しない() async throws {
        #expect(try await record(after: CCM_CRASH_ABORT_OFF_MAIN).record == nil)
    }

    @Test func 項目を消したあとのクラッシュは記録しない() async throws {
        #expect(try await record(after: CCM_CRASH_ABORT_AFTER_CLEAR).record == nil)
    }

    @Test func ハンドラーが動かない終了は記録しない() async throws {
        #expect(try await record(after: CCM_CRASH_KILLED).record == nil)
    }

    @Test func 長すぎる項目は記録しない() async throws {
        #expect(try await record(after: CCM_CRASH_ABORT, item: String(repeating: "1", count: 129)).record == nil)
    }

    @Test func ファイルがなければ記録もない() {
        #expect(CrashMark.takeRecord(fileAt: TestScratch.url("missing")) == nil)
    }

    /// 子プロセスが終わらなくても、待っている間にメインスレッドでこのテストの続きが走り、待つのをやめれば子プロセスを止めて戻る。
    @Test func 終わらない子プロセスを待つ間もメインスレッドは止まらない() async throws {
        let file = TestScratch.url("crash-mark")
        let started = Gate()
        let waiting = Task { @MainActor in
            try await CrashChild.run(file: file, account: "account", item: "1", kind: CCM_CRASH_NEVER, started: { started.open() })
        }
        try await started.wait()
        waiting.cancel()

        #expect(try await waiting.value == SIGKILL)
    }
}

/// 子プロセスでクラッシュさせ、終わるのを、メインスレッドも協調スレッドも止めずに待つ。
@MainActor private enum CrashChild {
    static func run(file: URL, account: String, item: String, kind: ccm_crash_kind, started: @Sendable () -> Void = {}) async throws -> Int32 {
        let child = file.withUnsafeFileSystemRepresentation { ccm_testing_start_crash_child($0, account, item, kind) }
        started()
        try #require(child > 0)
        let signal = await withTaskCancellationHandler {
            await termination(of: child)
        } onCancel: {
            kill(child, SIGKILL)
        }
        return signal
    }

    /// 子プロセスが終わるのを、待つだけの専用のスレッドで待つ。協調スレッドやGCDのスレッドを、子プロセスが終わるまで占めないため。
    private nonisolated static func termination(of child: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: ccm_testing_wait_child(child)) }.start()
        }
    }
}
