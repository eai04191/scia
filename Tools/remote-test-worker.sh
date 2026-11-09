#!/bin/bash
# Tools/test-dispatch.shが、テストを任せるMacへSSHで送って走らせる。treeの中身のtarを標準入力で受け取る。
# 使い方: remote-test-worker.sh <check|test|check-test> <tree> <依頼のID> <端末>...
# 渡した端末の数だけ、作業コピーと端末の組で同時に走らせる。
# SIGTERMを受けると、順番待ちでも実行中でも、この依頼だけを止めて終わる。Tools/test-dispatch.shは依頼のIDで~/scia/jobs/のPIDを引いて送る。
# 走らせると決まったら、標準出力の最初の行にそのことを書く。受け付けないときは標準出力に何も書かない。Tools/test-dispatch.shは最初の行で、受け付けられたと知る。
# 終了コード: 0 通った、75 受け付けない（貸し出しを止めている、電源につながっていない、組が全部ふさがっている）、それ以外 落ちたか、走らせられなかった
set -uo pipefail

target=$1
tree=$2
id=$3
sims=("${@:4}")
sim=

export PATH=/opt/homebrew/bin:$PATH
paused=/Users/Shared/scia-runner-paused

limit() {
    perl -e 'alarm shift; exec @ARGV' "$@"
}

refuse_if_not_lent() {
    if [ -e "$paused" ]; then
        echo "テストを任せるMacは貸し出しを止めています" >&2
        exit 75
    fi
    if ! pmset -g batt | grep -q "AC Power"; then
        echo "テストを任せるMacは電源につながっていません" >&2
        exit 75
    fi
}

# 空いている組のロックをファイル記述子8で取り、組の番号をslotに、端末をsimに入れる。空きがなければ待たずに失敗する
take_slot() {
    local i
    for i in "${!sims[@]}"; do
        exec 8> ~/scia/slot-$((i + 1)).lock
        if lockf -s -t 0 8; then
            slot=$((i + 1))
            sim=${sims[$i]}
            return 0
        fi
        exec 8>&-
    done
    return 1
}

incoming=
job=
on_term() {
    if [ -n "$job" ]; then
        kill -TERM -- "-$job" 2>/dev/null
        wait "$job"
        limit 40 xcrun simctl shutdown "$sim"
    fi
    exit 143
}

mkdir -p ~/scia/logs ~/scia/jobs ~/scia/results
echo "$$" > ~/scia/jobs/"$id".pid
trap 'rm -rf "$incoming" ~/scia/jobs/"$id".pid' EXIT
trap on_term TERM

refuse_if_not_lent

if ! take_slot; then
    echo "テストを任せるMacの組はすべてふさがっています" >&2
    exit 75
fi
echo "組${slot}（${sim}）で走らせます"

work=~/scia/tree-$slot
mkdir -p "$work" || exit 1
incoming=$(mktemp -d ~/scia/incoming.XXXXXX) || exit 1
tar -x -C "$incoming" || exit 1
# 中身の同じファイルの更新日時を変えると、差分ビルドが作り直すので、違うファイルだけを置き換える。実行ビットもtreeの中身なので-pで揃える
rsync -rlcp --delete --exclude-from="$incoming/.gitignore" --exclude=.git "$incoming/" "$work/" || exit 1

cd "$work" || exit 1
[ -d .git ] || git init -q -b job
git add -A
got=$(git write-tree)
if [ "$got" != "$tree" ]; then
    echo "error: 受け取った中身のtreeが違います: $got != $tree"
    exit 1
fi
git -c user.name=runner -c user.email=runner@localhost commit -q --allow-empty -m "job $tree"

# SSHのセッションごとにキーチェーンがロックされているので、SciaCoreのKeychainのテストの前に開ける
limit 15 security unlock-keychain -p '' login.keychain || { echo "error: キーチェーンを開けません"; exit 1; }
limit 150 xcrun simctl bootstatus "$sim" -b > /dev/null || { echo "error: $sim を起動できません"; exit 1; }

log=~/scia/logs/$tree.$target.$id.log
# ロックのファイル記述子を閉じてから起動する。xcodebuildの常駐プロセスが受け継ぐと、終わってもロックが外れないため
set -m
caffeinate -i make "$target-here" SIM="$sim" > "$log" 2>&1 8>&- &
job=$!
set +m

stopped=
while kill -0 "$job" 2>/dev/null; do
    if [ -e "$paused" ]; then
        stopped=1
        kill -TERM -- "-$job" 2>/dev/null
        break
    fi
    sleep 3
done
wait "$job"
result=$?
limit 40 xcrun simctl shutdown "$sim"
find ~/scia/logs -type f -mtime +7 -delete
find ~/scia/results -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} +

if [ -n "$stopped" ]; then
    echo "貸し出しを止めたので、テストを中断しました"
    exit 75
fi
# 落ちた回のxcresultを、Tools/test-dispatch.shが依頼のIDで受け取れる場所へ移す。作業コピーに残っている前の依頼の分は、この依頼の始まりより古いので移さない
if [ "$result" -ne 0 ]; then
    results=~/scia/results/$id
    mkdir -p "$results"
    find "$work/DerivedData/test-logs" -mindepth 1 -maxdepth 1 -type d -name 'failed-*' -newer ~/scia/jobs/"$id".pid -exec mv {} "$results/" \; 2>/dev/null
    rmdir "$results" 2>/dev/null
fi
grep -aE ': error: |\*\*\*|✘ Test|Test run with' "$log" | tail -30 | cut -c1-240
exit "$result"
