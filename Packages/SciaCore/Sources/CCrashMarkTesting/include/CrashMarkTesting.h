#ifndef CCRASHMARKTESTING_H
#define CCRASHMARKTESTING_H

typedef enum {
    CCM_CRASH_ABORT,
    CCM_CRASH_BAD_ACCESS,
    CCM_CRASH_TRAP,
    CCM_CRASH_STACK_OVERFLOW,
    CCM_CRASH_ABORT_OFF_MAIN,
    CCM_CRASH_ABORT_AFTER_CLEAR,
    CCM_CRASH_KILLED,
    /// 死なずに、止められるまで待ち続ける。
    CCM_CRASH_NEVER,
} ccm_crash_kind;

/// 子プロセスで`path`に記録を始め、`item`を処理している最中に`kind`で死ぬ。子プロセスのIDを返す。作れなければ-1。
/// 子プロセスが終わるのは待たない。`ccm_testing_wait_child`で受け取る。
int ccm_testing_start_crash_child(const char *path, const char *account, const char *item, ccm_crash_kind kind);

/// `child`が終わるまで待ち、止めたシグナルの番号を返す。シグナルで止まったのでなければ0。受け取れなければ-1。
int ccm_testing_wait_child(int child);

#endif
