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
} ccm_crash_kind;

/// 子プロセスで`path`に記録を始め、`item`を処理している最中に`kind`で死ぬ。子プロセスを止めたシグナルの番号を返す。止まらなければ0。
int ccm_testing_crash_child(const char *path, const char *account, const char *item, ccm_crash_kind kind);

#endif
