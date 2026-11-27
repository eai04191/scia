#!/bin/bash
# Tools/test-dispatch.shが、テストを任せるMacへSSHで送って走らせる。treeの中身のtarを標準入力で受け取る。
# 使い方: remote-test-worker.sh <check|test|check-test> <tree> <依頼のID> <DEVELOPMENT_TEAM（空なら付けない）> <依頼元のbranch> <依頼元のcommit> <queue（空なら組の作業コピー）> <端末>...
# 渡した端末の数だけ、作業コピーと端末の組で同時に走らせる。queueを渡すと、端末は空いている組のものを使い、作業コピーはmerge queueの回だけが使うtree-queueにする。
# SIGTERMを受けると、順番待ちでも実行中でも、この依頼だけを止めて終わる。Tools/test-dispatch.shは依頼のIDで~/scia/jobs/のPIDを引いて送る。
# 走らせると決まったら、標準出力の最初の行にそのことを書く。受け付けないときは標準出力に何も書かない。Tools/test-dispatch.shは最初の行で、受け付けられたと知る。
# 終了コード: 0 通った、75 受け付けない（貸し出しを止めている、電源につながっていない、組が全部ふさがっている）、それ以外 落ちたか、走らせられなかった
set -uo pipefail

target=$1
tree=$2
id=$3
team=$4
branch=$5
commit=$6
copy=$7
sims=("${@:8}")
sim=
slot=
sim_down=

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
        sim_down=1
    fi
    exit 143
}

# 端末は次の回のために起動したままにするので、回がどう終わっても、貸し出しを止めたら端末を止めるよう後ろで見張る。
# 止める間は組のロックを持ち、次の回が同じ組を取って起動した端末を、遅れて終わった停止で止めないようにする。組とtree-queueのロックを受け継がないよう、ファイル記述子を閉じる
watch_idle() {
    [ -n "$slot" ] && [ -z "$sim_down" ] || return 0
    ( while sleep 3; do
        [ -e "$paused" ] || continue
        exec 9> ~/scia/slot-$slot.lock
        if lockf -s -t 0 9; then
            limit 40 xcrun simctl shutdown "$sim"
            rm -f ~/scia/idle-watch-$slot.pid
            exit 0
        fi
        exec 9>&-
    done ) < /dev/null > /dev/null 2>&1 7>&- 8>&- &
    echo $! > ~/scia/idle-watch-$slot.pid
}

mkdir -p ~/scia/logs ~/scia/jobs ~/scia/results ~/scia/apps
echo "$$" > ~/scia/jobs/"$id".pid
# 段階の時間はTools/step-time.shでSCIA_STEP_LOGのファイルに書き、終わるときに「scia-step」を頭に付けて返す。Tools/test-dispatch.shがSCIA_STEP_LOGへ移す
# 途中で失敗したり止められたりした回の段階も返すよう、終わるときに出す
SCIA_STEP_LOG=
send_steps() {
    [ -z "$SCIA_STEP_LOG" ] || sed "s/^/scia-step	/" "$SCIA_STEP_LOG" 2>/dev/null
}
trap 'send_steps; rm -rf "$incoming" ~/scia/jobs/"$id".pid; watch_idle' EXIT
trap on_term TERM

refuse_if_not_lent

if ! take_slot; then
    echo "テストを任せるMacの組はすべてふさがっています" >&2
    exit 75
fi
echo "組${slot}（${sim}）で走らせます"
# 前の回が残した端末の見張りは、この回が引き継ぐ。見張りは組のロックを持つ間だけ端末を止めるので、ロックを取ったこの回が止めても、停止の途中ではない
[ ! -f ~/scia/idle-watch-$slot.pid ] || kill "$(cat ~/scia/idle-watch-$slot.pid)" 2>/dev/null
rm -f ~/scia/idle-watch-$slot.pid

transfer_start=$(date +%s)
work=~/scia/tree-$slot
# merge queueの回どうしは、mainの先頭へrebaseした中身なので差が小さい。組の作業コピーには、古いmainから分かれたbranchの中身が間に入り、差分ビルドが作り直しになるため、専用の作業コピーを使う
# 手元のmerge queueは1回ずつしか走らないが、接続が切れて手元で走らせ直した回の処理がここに残ることがあるので、ロック（ファイル記述子7）を取れたときだけ使い、取れなければ組の作業コピーで走らせる
if [ "$copy" = queue ]; then
    exec 7> ~/scia/tree-queue.lock
    if lockf -s -t 0 7; then
        work=~/scia/tree-queue
    else
        exec 7>&-
        copy=
    fi
fi
mkdir -p "$work" || exit 1
incoming=$(mktemp -d ~/scia/incoming.XXXXXX) || exit 1
tar -x -C "$incoming" || exit 1
# 中身の同じファイルの更新日時を変えると、差分ビルドが作り直すので、違うファイルだけを置き換える。実行ビットもtreeの中身なので-pで揃える
rsync -rlcp --delete --exclude-from="$incoming/.gitignore" --exclude=.git "$incoming/" "$work/" || exit 1

cd "$work" || exit 1
SCIA_STEP_LOG=~/scia/logs/$id.steps
export SCIA_STEP_LOG
Tools/step-time.sh record transfer "$transfer_start" 0
# 手元のビルドと同じapplication-identifierのアプリにするため、手元のDEVELOPMENT_TEAMを、手元と同じくConfig/Local.xcconfigから読ませる。.gitignoreにあるのでtreeには入らない
if [ -n "$team" ]; then
    echo "DEVELOPMENT_TEAM = $team" > Config/Local.xcconfig
else
    rm -f Config/Local.xcconfig
fi
# 専用の作業コピーは差分ビルドで速くなり、コンパイルキャッシュには頼らない。キャッシュは空きの50%まで溜まるので切る（Config/Cache.xcconfig）
if [ "$copy" = queue ]; then
    echo "COMPILATION_CACHE_ENABLE_CACHING[config=Debug] = NO" > Config/CacheLocal.xcconfig
fi
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
boot_start=$(date +%s)
limit 150 xcrun simctl bootstatus "$sim" -b > /dev/null || { echo "error: $sim を起動できません"; exit 1; }
Tools/step-time.sh record sim-boot "$boot_start" 0

log=~/scia/logs/$tree.$target.$id.log
# ロックのファイル記述子を閉じてから起動する。xcodebuildの常駐プロセスが受け継ぐと、終わってもロックが外れないため
make_start=$(date +%s)
set -m
SCIA_GIT_BRANCH=$branch SCIA_GIT_COMMIT=$commit caffeinate -i make "$target-here" SIM="$sim" > "$log" 2>&1 7>&- 8>&- &
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
Tools/step-time.sh record "$target" "$make_start" "$result"
# 端末は次の回のために起動したままにする。止めると、次の回で起動とアプリの立ち上げに約70秒よけいにかかる
if [ -n "$stopped" ]; then
    limit 40 xcrun simctl shutdown "$sim"
    sim_down=1
fi
find ~/scia/logs -type f -mtime +7 -delete
find ~/scia/results -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} +
find ~/scia/apps -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} +

if [ -n "$stopped" ]; then
    echo "貸し出しを止めたので、テストを中断しました"
    exit 75
fi
# 落ちた回のxcresultと、走らせた出力の全文を、Tools/test-dispatch.shが依頼のIDで受け取れる場所へ移す。作業コピーに残っている前の依頼の分は、この依頼の始まりより古いので移さない
# 出力の全文は、作業コピーの分（checkの残りのDerivedData/check-rest.log、対象ごとのDerivedData/check-logs）が次の依頼に上書きされるため、ここでコピーする
if [ "$result" -ne 0 ]; then
    results=~/scia/results/$id
    mkdir -p "$results"
    find "$work/DerivedData/test-logs" -mindepth 1 -maxdepth 1 -type d -name 'failed-*' -newer ~/scia/jobs/"$id".pid -exec mv {} "$results/" \; 2>/dev/null
    output=$results/remote-output-$id
    mkdir -p "$output"
    cp "$log" "$output/make.log"
    find "$work/DerivedData" -maxdepth 1 -name check-rest.log -newer ~/scia/jobs/"$id".pid -exec cp {} "$output/" \;
    find "$work/DerivedData/check-logs" -type f -newer ~/scia/jobs/"$id".pid -exec cp {} "$output/" \; 2>/dev/null
fi
# 通った回のアプリ（Tools/keep-checked-app.shが残したもの）を、Tools/test-dispatch.shが依頼のIDで受け取れる場所へコピーする。作業コピーは次の依頼が上書きするため
if [ "$result" -eq 0 ] && [ -d "$work/DerivedData/checked" ]; then
    cp -Rc "$work/DerivedData/checked" ~/scia/apps/"$id"
fi
grep -aE ': error: |\*\*\*|✘ Test|Test run with' "$log" | tail -30 | cut -c1-240
# 落ちた対象の出力（Tools/check-logged.shの見出しから見出しまで）は、形で選んだ行に入らないことがあるので、そのまま返す
sed -n '/^==== 落ちた: /,/^==== ここまで: /p' "$log"
exit "$result"
