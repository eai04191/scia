#!/bin/sh
# make checkで並べて走らせる対象を1つ走らせ、出力をその対象のログに書く。落ちたら、見出しの間に、ログ全体から選んだ失敗の行と、ログの末尾を入れた区間を<対象>.failedに書く。
# 失敗の行はSwiftのテストとビルドの形で選ぶ。末尾も入れるのは、Pythonのunittestの「FAIL: …」のような形の違う行を落とさないため。
# 区間は、並べた対象が全部終わってからMakefileがまとめて出す。同時に落ちた対象が並べて出すと区間が交ざり、見出しで選ぶときに片方が欠けるため。
# 見出しの行は、Tools/remote-test-worker.shが、落ちた対象の出力を選ぶのに使う。
# 使い方: check-logged.sh <ログのフォルダー> <対象の名前> <コマンド>...
set -u
dir=$1
name=$2
shift 2
mkdir -p "$dir"
log=$dir/$name.log
start=$(date +%s)
"$@" > "$log" 2>&1
status=$?
"$(dirname "$0")/step-time.sh" record "$name" "$start" "$status"
if [ "$status" -ne 0 ]; then
    {
        echo "==== 落ちた: ${name}（全文: ${log}）"
        grep -aE ': error: |recorded an issue|failed after|✘ Test' "$log" | head -n 40 | cut -c1-400
        echo "---- 末尾"
        tail -n 80 "$log" | cut -c1-400
        echo "==== ここまで: ${name}"
    } > "$dir/$name.failed"
fi
exit "$status"
