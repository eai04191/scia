#include "CrashMark.h"

#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// シグナルハンドラーから触るため、Swiftではなく、確保も排他も使わないCで書く。
// ファイルをMAP_SHAREDで対応づけるので、書いたページはプロセスが死んでもカーネルに残る。

enum { CCM_FILE_SIZE = 4096 };
static const uint32_t CCM_MAGIC = 0x53434D31;

typedef struct {
    uint32_t magic;
    uint32_t did_crash;
    int32_t signal_number;
    uint32_t item_length;
    uint32_t account_length;
    char item[CCM_MAX_ITEM];
    char account[CCM_MAX_ACCOUNT];
} ccm_region;

_Static_assert(sizeof(ccm_region) <= CCM_FILE_SIZE, "記録はファイルの大きさに収める");

static const int ccm_signals[] = { SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP };
enum { CCM_SIGNAL_COUNT = sizeof(ccm_signals) / sizeof(ccm_signals[0]) };

static ccm_region *ccm_mapped;
static struct sigaction ccm_previous[CCM_SIGNAL_COUNT];
// スタックを使い切ったクラッシュでもハンドラーが動くよう、別のスタックを用意する。
static char ccm_stack[64 * 1024];

static void ccm_restore(int signal_number) {
    for (int i = 0; i < CCM_SIGNAL_COUNT; i++) {
        if (ccm_signals[i] == signal_number) {
            sigaction(signal_number, &ccm_previous[i], NULL);
        }
    }
}

static void ccm_handle(int signal_number, siginfo_t *info, void *context) {
    (void)info;
    (void)context;
    ccm_region *region = ccm_mapped;
    // ほかのスレッドのクラッシュは、メインスレッドで処理していた項目のせいとは言えない。
    if (region != NULL && pthread_main_np() != 0 && region->item_length > 0) {
        region->signal_number = signal_number;
        region->did_crash = 1;
    }
    // 元の扱いに戻して投げ直す。OSのクラッシュログ（TestFlightに届くもの）を今までどおり残すため。
    ccm_restore(signal_number);
    raise(signal_number);
}

static bool ccm_is_valid(const ccm_region *region) {
    return region->magic == CCM_MAGIC
        && region->item_length > 0 && region->item_length <= CCM_MAX_ITEM
        && region->account_length <= CCM_MAX_ACCOUNT;
}

bool ccm_take_record(const char *path, ccm_record *out) {
    int file = open(path, O_RDWR);
    if (file < 0) {
        return false;
    }
    ccm_region region;
    bool found = pread(file, &region, sizeof(region), 0) == (ssize_t)sizeof(region)
        && region.did_crash == 1
        && ccm_is_valid(&region);
    if (found) {
        memset(out, 0, sizeof(*out));
        memcpy(out->item, region.item, region.item_length);
        memcpy(out->account, region.account, region.account_length);
        out->signal_number = region.signal_number;
    }
    ccm_region empty;
    memset(&empty, 0, sizeof(empty));
    (void)pwrite(file, &empty, sizeof(empty), 0);
    close(file);
    return found;
}

bool ccm_install(const char *path) {
    if (ccm_mapped != NULL) {
        return true;
    }
    int file = open(path, O_RDWR | O_CREAT, 0600);
    if (file < 0) {
        return false;
    }
    if (ftruncate(file, CCM_FILE_SIZE) != 0) {
        close(file);
        return false;
    }
    void *mapped = mmap(NULL, CCM_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
    close(file);
    if (mapped == MAP_FAILED) {
        return false;
    }
    ccm_region *region = mapped;
    memset(region, 0, sizeof(*region));
    region->magic = CCM_MAGIC;
    ccm_mapped = region;

    stack_t stack = { .ss_sp = ccm_stack, .ss_size = sizeof(ccm_stack), .ss_flags = 0 };
    sigaltstack(&stack, NULL);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = ccm_handle;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    for (int i = 0; i < CCM_SIGNAL_COUNT; i++) {
        sigaction(ccm_signals[i], &action, &ccm_previous[i]);
    }
    return true;
}

void ccm_set_account(const char *bytes, size_t length) {
    ccm_region *region = ccm_mapped;
    if (region == NULL) {
        return;
    }
    region->account_length = 0;
    if (length == 0 || length > CCM_MAX_ACCOUNT) {
        return;
    }
    memcpy(region->account, bytes, length);
    atomic_signal_fence(memory_order_seq_cst);
    region->account_length = (uint32_t)length;
}

void ccm_set_item(const char *bytes, size_t length) {
    ccm_region *region = ccm_mapped;
    if (region == NULL) {
        return;
    }
    region->item_length = 0;
    if (length == 0 || length > CCM_MAX_ITEM) {
        return;
    }
    memcpy(region->item, bytes, length);
    atomic_signal_fence(memory_order_seq_cst);
    region->item_length = (uint32_t)length;
}

void ccm_clear_item(void) {
    ccm_region *region = ccm_mapped;
    if (region != NULL) {
        region->item_length = 0;
    }
}
