#!/bin/bash
# 作業branchを、1つずつローカルのmainへ入れる。/merge-to-mainのskillが、作業branchのworktreeでバックグラウンドで走らせる。
# 番が来たら、最新のmainへrebaseし、Tools/check-stamp.shでまだ通っていないmake checkとmake testだけを走らせ、fast-forwardで入れる。
# 判断の要ること（rebaseのconflict、落ちたcheckやtest、未commitの変更、来ない前提、人が承認していないFEATURES.mdとREADME.mdの変更）は扱わず、番を譲って終わる。直したら並び直す。
# 列は、worktreeどうしで共有する.gitの共通ディレクトリのscia-merge-queue/に、並んだ順の番号を名前にしたファイルで置く。
# 番は、前提がすべてmainに入っている並びのうち、一番前のものに来る。前提を待つ並びは、後ろのものに追い越される。
# 追い越しがあると並んだ順だけでは1つずつにならないので、mainへ入れる処理は、.turnのロックを持って走らせる。
# ロックはlockfのプロセスが持つので、処理から起動したmakeやxcodebuildが常駐のプロセスを残しても、ロックは残らない。
# 並びを持つのはこのスクリプトのプロセス。止められたり落ちたりしてプロセスが消えた並びは、次に列を見たプロセスが消す。
# 使い方:
#   Tools/merge-queue.sh run [<前提のbranch>...]   今のbranchを列に並べ、番が来たら入れる。make checkとmake testは、Tools/test-dispatch.shで空いている枠へ振り分けて走らせる
#   Tools/merge-queue.sh status                         並んでいるbranchを順に出す
# runを止めると（SIGTERM、SIGINT、SIGHUP）、mainへ入れている途中なら、走らせているrebaseやmakeを止め、rebaseを取りやめて端末を返してから終わる。
#   fast-forwardを始めたあとは、mainを中途半端にしないよう、入れ終えてから終わる。止めたときの終了コードは、シグナルの番号に128を足したもの
# runの終了コード: 0 入れた、1 使い方の誤りや想定外の失敗、2 未commitの変更がある、3 rebaseがconflictした、4 make checkかmake testが落ちた、
#   5 前提のbranchが、列にもmainにもないまま10分経った、6 FEATURES.mdかREADME.mdの変更を人が承認していない（Tools/human-review.sh）
# 段階ごとにかかった時間は、列のディレクトリのtiming.logに1行ずつ足す。列は「始めた時刻 branch 段階 秒 結果」のタブ区切りで、結果はokか終了コード。
#   段階は、wait（並んでから番が来るまで）、rebase、check、test、check-test（checkとtestの両方を走らせるとき。枠を待つ時間も含む）、total（並んでから終わるまで）。
#   mainが動いて載せ直すと、rebaseからの段階がもう一度並ぶ
set -euo pipefail

TARGET=main
POLL_SECONDS=3
# 前提のスレッドへの合図が、後のスレッドへの合図より遅れても間に合うだけの長さ
ABSENT_LIMIT_SECONDS=600
# lockfが、ロックを取れなかったときに返す終了コード（sysexits.hのEX_TEMPFAIL）
LOCK_BUSY=75
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

queue_dir() {
    echo "$(git rev-parse --path-format=absolute --git-common-dir)/scia-merge-queue"
}

# runが並べたbranchと並んだ時刻。landはlockfから別のプロセスで走るので、環境変数で受け取る
MERGE_QUEUE_BRANCH=${MERGE_QUEUE_BRANCH:-}
MERGE_QUEUE_QUEUED_AT=${MERGE_QUEUE_QUEUED_AT:-}

# 段階の名前、始めたUNIX時刻、結果（終了コード）を受け取り、timing.logに1行足す
log_timing() {
    local result=$3
    [[ "$result" == 0 ]] && result=ok
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -r "$2" '+%Y-%m-%dT%H:%M:%S%z')" "$MERGE_QUEUE_BRANCH" "$1" "$(( $(date +%s) - $2 ))" "$result" >> "$(queue_dir)/timing.log"
}

# landが走らせている子のプロセス（自分のプロセスグループの長）と、その段階の名前と始めた時刻。止められたときに、子を止めて段階を記録する
child=''
child_phase=''
child_start=''
# 子を起動してからPIDを覚えるまでの間か。その間に届いた止める合図は、覚えてから扱う。覚える前に扱うと、子を止められないため
starting=''
pending_signal=''

# 段階の名前とコマンドを受け取り、コマンドを走らせてかかった時間をtiming.logに足す。コマンドの終了コードを返す
# 前面で走らせると、止める合図のtrapが子の終わるまで走らないので、自分のプロセスグループで後ろで走らせて待つ。
# グループを分けるのは、makeから起動したxcodebuildなどの孫までまとめて止めるため
timed() {
    local status=0
    child_phase=$1
    shift
    child_start=$(date +%s)
    starting=1
    set -m
    "$@" &
    child=$!
    set +m
    starting=''
    [[ -z "$pending_signal" ]] || on_land_signal "$pending_signal"
    wait "$child" || status=$?
    child=''
    log_timing "$child_phase" "$child_start" "$status"
    return "$status"
}

# 並びのファイルは、1行目がプロセスID、2行目がbranch、3行目がworktree、4行目が空白で区切った前提のbranch
entry_field() {
    sed -n "$2p" "$1"
}

# プロセスIDは使い回されるので、IDが生きているだけでなく、このスクリプトのプロセスかも見る
alive() {
    local pid command
    pid=$(entry_field "$1" 1)
    command=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
    [[ "$command" == *merge-queue.sh* ]]
}

# 生きている並びを、並んだ順に出す。消えたプロセスの並びは消す
live_entries() {
    local entry
    for entry in "$(queue_dir)"/[0-9]*; do
        [[ -e "$entry" ]] || continue
        if alive "$entry"; then
            echo "$entry"
        else
            echo "$(entry_field "$entry" 2) のプロセスがもういないので、列から外します" >&2
            rm -f "$entry"
        fi
    done
}

enqueue() {
    local dir seq entry
    dir=$(queue_dir)
    mkdir -p "$dir"
    # 番号を取って並びを置くまでを、ほかのプロセスと重ねない。flockのロックはプロセスが消えると外れる
    exec 9>"$dir/.lock"
    lockf -s 9
    seq=$(( $(cat "$dir/.seq" 2>/dev/null || echo 0) + 1 ))
    echo "$seq" > "$dir/.seq"
    entry="$dir/$(printf '%010d' "$seq")"
    # 書きかけのファイルを、ほかのプロセスが空のプロセスIDと読んで消さないよう、名前の違う一時ファイルに書いてから置く
    printf '%s\n%s\n%s\n%s\n' "$$" "$(git symbolic-ref --short HEAD)" "$(git rev-parse --show-toplevel)" "$*" > "$dir/.tmp-$$"
    mv "$dir/.tmp-$$" "$entry"
    exec 9>&-
    echo "$entry"
}

merged() {
    git merge-base --is-ancestor "refs/heads/$1" "$TARGET"
}

# 前提がすべてmainに入っているか
ready() {
    local dep
    for dep in $(entry_field "$1" 4); do
        merged "$dep" || return 1
    done
}

# 自分より前に、番を待てる並びがあるか
ready_ahead() {
    local me=$1 entries=$2 entry
    while read -r entry; do
        [[ "$entry" == "$me" ]] && return 1
        ready "$entry" && return 0
    done <<< "$entries"
    return 1
}

# まだmainに入っていない前提のうち、列にも並んでいないものを出す
absent_deps() {
    local me=$1 entries=$2 dep entry queued
    for dep in $(entry_field "$me" 4); do
        merged "$dep" && continue
        queued=
        while read -r entry; do
            [[ -n "$entry" && "$(entry_field "$entry" 2)" == "$dep" ]] && queued=1
        done <<< "$entries"
        [[ -z "$queued" ]] && echo "$dep"
    done
    return 0
}

# 番を取りに走らせているlockfのプロセス
lock_holder=''
# lockfを起動してからPIDを覚えるまでの間か。その間に届いた止める合図は、覚えてから扱う
lock_starting=''
pending_run_signal=''

# runが止める合図を受けたときに、終了コードと受けたシグナルの名前を受け取って呼ばれる。
# lockfを止めると、landが動いている間にロックが外れ、ほかの並びがmainを動かし始めるので、lockfの子のlandにだけ伝え、landが終わるのを待つ。
# landが入れ終えていれば、その終了コードで終わる
on_run_signal() {
    local lander state status=0
    if [[ -n "$lock_starting" ]]; then
        pending_run_signal="$1 $2"
        return
    fi
    if [[ -n "$lock_holder" ]]; then
        while :; do
            # lockfが子を起動する前なら、子を待って伝える。ロックを取れずに終わったlockfは、waitするまで終わった状態で残る
            state=$(ps -p "$lock_holder" -o stat= 2>/dev/null) || break
            [[ "$state" == Z* ]] && break
            if lander=$(pgrep -P "$lock_holder"); then
                kill -s "$2" "$lander"
                break
            fi
            sleep 0.1
        done
        wait "$lock_holder" || status=$?
        [[ "$status" == "$LOCK_BUSY" ]] || exit "$status"
    fi
    exit "$1"
}

# 番が来て入れ終わるか、判断の要ることで終わるまで待つ。入れる処理の終了コードで終わる
wait_and_land() {
    local me=$1 dep since expired entries absent absent_since='' status shown='' message turn
    while :; do
        for dep in $(entry_field "$me" 4); do
            git rev-parse -q --verify "refs/heads/$dep" > /dev/null || { echo "error: 前提のbranch $dep がなくなりました" >&2; exit 1; }
        done
        entries=$(live_entries)
        if ! grep -qxF "$me" <<< "$entries"; then
            echo "error: 自分の並びが列から消えたので、終わります。並び直してください" >&2
            exit 1
        fi

        # 前提ごとに、列にもmainにもなくなった時刻を「branch 時刻」の行で持つ。途中で列に並んだものは、測り直す
        absent=$(absent_deps "$me" "$entries")
        absent_since=$(while read -r dep; do
            [[ -n "$dep" ]] || continue
            since=$(awk -v dep="$dep" '$1 == dep { print $2 }' <<< "$absent_since")
            echo "$dep ${since:-$SECONDS}"
        done <<< "$absent")
        expired=$(awk -v now="$SECONDS" -v limit="$ABSENT_LIMIT_SECONDS" 'NF == 2 && now - $2 >= limit { printf "%s ", $1 }' <<< "$absent_since")
        if [[ -n "$expired" ]]; then
            echo "error: 前提の ${expired}が、列にもmainにもないまま$((ABSENT_LIMIT_SECONDS / 60))分経ったので、列を離れます" >&2
            exit 5
        fi

        if ready "$me" && ! ready_ahead "$me" "$entries"; then
            status=0
            # 後ろで走らせたプロセスの子をlandと見なすので、引数のコマンド置換を後ろのプロセスの中で走らせない
            turn="$(queue_dir)/.turn"
            # 止める合図をすぐ受けられるよう後ろで走らせて待つ。ターミナルのCtrl-Cがlockfとlandに直に届かないよう、プロセスグループを分ける
            lock_starting=1
            set -m
            lockf -s -k -t 0 "$turn" "$SELF" land &
            lock_holder=$!
            set +m
            lock_starting=''
            # 文字列の分割で、終了コードとシグナルの名前の2つの引数にする
            # shellcheck disable=SC2086
            [[ -z "$pending_run_signal" ]] || on_run_signal $pending_run_signal
            wait "$lock_holder" || status=$?
            lock_holder=''
            [[ "$status" == "$LOCK_BUSY" ]] || exit "$status"
            message="ほかの並びがmainへ入れているので、待っています"
        elif ready "$me"; then
            message="前に番を待つものが並んでいます"
        else
            message="前提の $(entry_field "$me" 4) がmainに入るのを待っています"
        fi
        if [[ "$message" != "$shown" ]]; then
            echo "$message"
            shown=$message
        fi
        sleep "$POLL_SECONDS"
    done
}

# mainをcheckoutしているworktreeを出す。なければ何も出さない
target_worktree() {
    git worktree list --porcelain | awk -v ref="refs/heads/$TARGET" '
        /^worktree / { path = substr($0, 10) }
        $0 == "branch " ref { print path }
    '
}

require_clean() {
    if [[ -n "$(git -C "$1" status --porcelain)" ]]; then
        echo "error: $1 に未commitの変更があるので、入れません" >&2
        exit 2
    fi
}

rebase_onto_target() {
    git merge-base --is-ancestor "$TARGET" HEAD && return
    echo "$(git rev-parse --short HEAD) を $TARGET（$(git rev-parse --short "$TARGET")）へrebaseします"
    if ! timed rebase git rebase "$TARGET"; then
        git rebase --abort
        echo "error: $TARGET へのrebaseがconflictしたので、取りやめて列を離れます。解決してから並び直してください" >&2
        exit 3
    fi
}

# 承認はユーザーを待つので、make checkとmake testに時間を使う前に調べる
require_human_review() {
    local missing
    missing=$(Tools/human-review.sh missing HEAD "$TARGET") || { echo "error: 人が承認したかを調べられませんでした" >&2; exit 1; }
    if [[ -n "$missing" ]]; then
        echo "error: $(echo $missing)の変更を人が承認していないので、列を離れます。ユーザーが自分の端末で Tools/human-review.sh approve $(git rev-parse --short HEAD) を走らせて承認してから、並び直してください" >&2
        exit 6
    fi
}

run_missing_steps() {
    local missing steps target
    # READMEだけが違うとmake checkを省くので、JSONと書き出したものが合っているかはここで必ず調べる
    python3 Tools/generate-app-info.py --check || { echo "error: Config/app-info.jsonと書き出したものが合っていません" >&2; exit 4; }
    # 調べられなかったときに、出力が空なのを通ったものと取り違えないよう、失敗したら止める
    missing=$(Tools/check-stamp.sh missing HEAD "$TARGET") || { echo "error: 通っていないものを調べられませんでした" >&2; exit 1; }
    steps=" $(awk '{ print $2 }' <<< "$missing" | tr '\n' ' ')"
    if [[ "$steps" == *" check "* && "$steps" == *" test "* ]]; then
        target=check-test
    elif [[ "$steps" == *" check "* ]]; then
        target=check
    elif [[ "$steps" == *" test "* ]]; then
        target=test
    else
        return 0
    fi
    # 待たせるとmainへ入れる処理の全体が止まるので、列の先頭に並ぶ
    timed "$target" Tools/test-dispatch.sh dispatch "$target" '' '' front || { echo "error: make $target が落ちました" >&2; exit 4; }
}

fast_forward() {
    local branch worktree
    branch=$(git symbolic-ref --short HEAD)
    worktree=$(target_worktree)
    if [[ -n "$worktree" ]]; then
        require_clean "$worktree"
        git -C "$worktree" merge --ff-only "$branch"
    else
        git fetch . "$branch:$TARGET"
    fi
}

# fast-forwardを始めたか。始めたあとに届いた止める合図は、入れ終えるまで待たせる
fast_forwarding=''

# landが止める合図を受けたときに、終了コードを受け取って呼ばれる
on_land_signal() {
    if [[ -n "$starting" ]]; then
        pending_signal=$1
        return
    fi
    if [[ -n "$fast_forwarding" ]]; then
        echo "止める合図が来ましたが、fast-forwardを始めていたので、入れ終えてから終わります" >&2
        return
    fi
    if [[ -n "$child" ]]; then
        kill -TERM -- "-$child" 2>/dev/null || true
        wait "$child" || true
        # 直接の子が終わっても、孫が終わる処理を続けていることがあり、その間にrebaseを取りやめたり端末を返したりすると重なるので、グループが空になるまで待つ
        while pgrep -g "$child" > /dev/null; do
            sleep 0.2
        done
        log_timing "$child_phase" "$child_start" "$1"
    fi
    if [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]; then
        git rebase --abort
    fi
    echo "error: 止められたので、$TARGET へ入れずに終わります" >&2
    exit "$1"
}

# .turnのロックを持った状態で、lockfから呼ばれる
land() {
    local before
    trap 'on_land_signal 129' HUP
    trap 'on_land_signal 130' INT
    trap 'on_land_signal 143' TERM
    echo "番が来ました"
    log_timing wait "$MERGE_QUEUE_QUEUED_AT" 0
    # 並んでから番が来るまでの間に変えたファイルを、確かめていない中身として入れないよう、もう一度確かめる
    require_clean "$(git rev-parse --show-toplevel)"
    # checkとtestの間に誰かがmainを動かしたら、載せ直して足りないものを通し直す
    while :; do
        before=$(git rev-parse "$TARGET")
        rebase_onto_target
        require_human_review
        run_missing_steps
        [[ "$(git rev-parse "$TARGET")" == "$before" ]] && break
        echo "$TARGET が動いたので、載せ直します"
    done
    fast_forwarding=1
    fast_forward
    echo "$TARGET へ入れました:"
    git log --oneline "$before..$TARGET"
}

run() {
    local dep
    for dep in "$@"; do
        git rev-parse -q --verify "refs/heads/$dep" > /dev/null || { echo "error: 前提のbranch $dep がありません" >&2; exit 1; }
    done
    require_clean "$(git rev-parse --show-toplevel)"
    MERGE_QUEUE_BRANCH=$(git symbolic-ref --short HEAD)
    MERGE_QUEUE_QUEUED_AT=$(date +%s)
    export MERGE_QUEUE_BRANCH MERGE_QUEUE_QUEUED_AT
    # trapは関数を抜けたあとに走るので、並びのファイルはグローバルに持つ
    entry=$(enqueue "$@")
    trap 'exit_status=$?; rm -f "$entry"; log_timing total "$MERGE_QUEUE_QUEUED_AT" "$exit_status"' EXIT
    # シグナルで止めると、EXITのtrapの$?が0になり、totalが止めた実行もokと残るので、シグナルの終了コードで抜ける
    trap 'on_run_signal 129 HUP' HUP
    trap 'on_run_signal 130 INT' INT
    trap 'on_run_signal 143 TERM' TERM
    echo "$(git symbolic-ref --short HEAD) を列に並べました"
    wait_and_land "$entry"
}

status() {
    local entry deps
    for entry in $(live_entries); do
        deps=$(entry_field "$entry" 4)
        echo "$(entry_field "$entry" 2)	$(entry_field "$entry" 3)${deps:+	前提: $deps}"
    done
}

case "${1:-}" in
    run)
        shift
        run "$@"
        ;;
    land)
        land
        ;;
    status)
        status
        ;;
    *)
        echo "使い方: Tools/merge-queue.sh run [<前提のbranch>...] | status" >&2
        exit 1
        ;;
esac
