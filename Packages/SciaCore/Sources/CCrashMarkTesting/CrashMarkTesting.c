#include "CrashMarkTesting.h"

#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "CrashMark.h"

__attribute__((noinline)) static int ccm_testing_recurse(volatile int depth) {
    volatile char padding[4096];
    padding[0] = (char)depth;
    return ccm_testing_recurse(depth + 1) + padding[0];
}

static void *ccm_testing_abort_thread(void *argument) {
    (void)argument;
    abort();
}

static void ccm_testing_crash(ccm_crash_kind kind) {
    switch (kind) {
    case CCM_CRASH_ABORT:
        abort();
    case CCM_CRASH_BAD_ACCESS:
        *(volatile int *)8 = 1;
        break;
    case CCM_CRASH_TRAP:
        __builtin_trap();
    case CCM_CRASH_STACK_OVERFLOW:
        ccm_testing_recurse(0);
        break;
    case CCM_CRASH_ABORT_OFF_MAIN: {
        pthread_t thread;
        pthread_create(&thread, NULL, ccm_testing_abort_thread, NULL);
        pthread_join(thread, NULL);
        break;
    }
    case CCM_CRASH_ABORT_AFTER_CLEAR:
        ccm_clear_item();
        abort();
    case CCM_CRASH_KILLED:
        kill(getpid(), SIGKILL);
        break;
    }
}

int ccm_testing_crash_child(const char *path, const char *account, const char *item, ccm_crash_kind kind) {
    pid_t child = fork();
    if (child == 0) {
        if (!ccm_install(path)) {
            _exit(100);
        }
        ccm_set_account(account, strlen(account));
        ccm_set_item(item, strlen(item));
        ccm_testing_crash(kind);
        _exit(101);
    }
    int status = 0;
    waitpid(child, &status, 0);
    return WIFSIGNALED(status) ? WTERMSIG(status) : 0;
}
