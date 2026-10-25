#!/bin/bash
# 作業branchを、1つずつローカルのmainへ入れる。/merge-to-mainのskillが、作業branchのworktreeでバックグラウンドで走らせる。
# 番が来たら、最新のmainへrebaseし、Tools/check-stamp.shでまだ通っていないmake checkとmake testだけを走らせ、fast-forwardで入れる。
# 判断の要ること（rebaseのconflict、落ちたcheckやtest、未commitの変更、来ない前提）は扱わず、番を譲って終わる。直したら並び直す。
# 列は、worktreeどうしで共有する.gitの共通ディレクトリのscia-merge-queue/に、並んだ順の番号を名前にしたファイルで置く。
# 番は、前提がすべてmainに入っている並びのうち、一番前のものに来る。前提を待つ並びは、後ろのものに追い越される。
# 追い越しがあると並んだ順だけでは1つずつにならないので、mainへ入れる処理は、.turnのロックを持って走らせる。
# ロックはlockfのプロセスが持つので、処理から起動したmakeやxcodebuildが常駐のプロセスを残しても、ロックは残らない。
# 並びを持つのはこのスクリプトのプロセス。止められたり落ちたりしてプロセスが消えた並びは、次に列を見たプロセスが消す。
# 使い方:
#   Tools/merge-queue.sh run <端末> [<前提のbranch>...]   今のbranchを列に並べ、番が来たら入れる。<端末>はmake testのSIMに渡す
#   Tools/merge-queue.sh status                         並んでいるbranchを順に出す
# runの終了コード: 0 入れた、1 使い方の誤りや想定外の失敗、2 未commitの変更がある、3 rebaseがconflictした、4 make checkかmake testが落ちた、
#   5 前提のbranchが、列にもmainにもないまま10分経った
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

# 番が来て入れ終わるか、判断の要ることで終わるまで待つ。入れる処理の終了コードで終わる
wait_and_land() {
    local me=$1 sim=$2 dep since expired entries absent absent_since='' status shown='' message
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
            lockf -s -k -t 0 "$(queue_dir)/.turn" "$SELF" land "$sim" || status=$?
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
    if ! git rebase "$TARGET"; then
        git rebase --abort
        echo "error: $TARGET へのrebaseがconflictしたので、取りやめて列を離れます。解決してから並び直してください" >&2
        exit 3
    fi
}

run_missing_steps() {
    local sim=$1 missing steps step
    # 調べられなかったときに、出力が空なのを通ったものと取り違えないよう、失敗したら止める
    missing=$(Tools/check-stamp.sh missing HEAD "$TARGET") || { echo "error: 通っていないものを調べられませんでした" >&2; exit 1; }
    steps=$(awk '{ print $2 }' <<< "$missing")
    for step in $steps; do
        echo "make $step を走らせます"
        if [[ "$step" == test ]]; then
            make test SIM="$sim" || { echo "error: make test が落ちました" >&2; exit 4; }
        else
            make "$step" || { echo "error: make $step が落ちました" >&2; exit 4; }
        fi
    done
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

# .turnのロックを持った状態で、lockfから呼ばれる
land() {
    local sim=$1 before
    echo "番が来ました"
    # 並んでから番が来るまでの間に変えたファイルを、確かめていない中身として入れないよう、もう一度確かめる
    require_clean "$(git rev-parse --show-toplevel)"
    # checkとtestの間に誰かがmainを動かしたら、載せ直して足りないものを通し直す
    while :; do
        before=$(git rev-parse "$TARGET")
        rebase_onto_target
        run_missing_steps "$sim"
        [[ "$(git rev-parse "$TARGET")" == "$before" ]] && break
        echo "$TARGET が動いたので、載せ直します"
    done
    fast_forward
    echo "$TARGET へ入れました:"
    git log --oneline "$before..$TARGET"
}

run() {
    local sim=${1:?make testに使う端末を渡す} dep
    shift
    for dep in "$@"; do
        git rev-parse -q --verify "refs/heads/$dep" > /dev/null || { echo "error: 前提のbranch $dep がありません" >&2; exit 1; }
    done
    require_clean "$(git rev-parse --show-toplevel)"
    # trapは関数を抜けたあとに走るので、並びのファイルはグローバルに持つ
    entry=$(enqueue "$@")
    trap 'rm -f "$entry"' EXIT
    echo "$(git symbolic-ref --short HEAD) を列に並べました"
    wait_and_land "$entry" "$sim"
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
        land "${2:?}"
        ;;
    status)
        status
        ;;
    *)
        echo "使い方: Tools/merge-queue.sh run <端末> [<前提のbranch>...] | status" >&2
        exit 1
        ;;
esac
