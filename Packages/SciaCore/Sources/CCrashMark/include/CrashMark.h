#ifndef CCRASHMARK_H
#define CCRASHMARK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CCM_MAX_ITEM 128
#define CCM_MAX_ACCOUNT 512

/// 前の起動が残した、クラッシュの記録。
typedef struct {
    char item[CCM_MAX_ITEM + 1];
    char account[CCM_MAX_ACCOUNT + 1];
    int32_t signal_number;
} ccm_record;

/// `path`のファイルに残ったクラッシュの記録を`out`に読み、ファイルを空にする。記録があればtrue。
/// シグナルハンドラーを入れないので、記録を読むだけのプロセスからも呼べる。
bool ccm_take_record(const char *path, ccm_record *out);

/// `path`のファイルをメモリに対応づけ、シグナルハンドラーを入れる。メインスレッドから1度だけ呼ぶ。入れられたらtrue。
bool ccm_install(const char *path);

/// 使っているアカウントを記録する。メインスレッドから呼ぶ。
void ccm_set_account(const char *bytes, size_t length);

/// メインスレッドで処理している項目を記録する。長すぎる項目は記録しない。メインスレッドから呼ぶ。
void ccm_set_item(const char *bytes, size_t length);

/// 処理している項目の記録を消す。メインスレッドから呼ぶ。
void ccm_clear_item(void);

#endif
