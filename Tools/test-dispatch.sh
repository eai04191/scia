#!/bin/bash
# make check、make test、make check-testを、空いている枠で走らせる入口。makeとTools/merge-queue.shの両方がここを通る。決まりはdocs/test-dispatch.md。
# 流れ: 順番札を取る → 札が先頭になるまで待つ → 別のMacに依頼する → 断られたら手元の枠を取る → どちらも空いていなければ、間をおいて別のMacから試し直す。
# 使い方:
#   Tools/test-dispatch.sh dispatch <target> '<SIM>' '<ONLY>' [front]   空いている枠で走らせ、その結果の終了コードで終わる。frontを付けると列の先頭に並ぶ
#   Tools/test-dispatch.sh remote <target>                               今の作業ツリーの中身を別のMacに1回依頼する。dispatchが呼ぶ
# remoteの終了コード: 0 通った、1 使い方の誤りや想定外の失敗、2 落ちた、69 届かない、75 受け付けない（設定がない、SCIA_REMOTE_TEST=local、貸し出しを止めている、電源につながっていない、組が全部ふさがっている）
set -euo pipefail

UNREACHABLE=69
NOT_ACCEPTED=75
LOCAL_SLOTS=2
POLL_SECONDS=5

dispatch() {
    local target=$1 sim=${2:-} only=${3:-} front=${4:-}
    valid_target "$target"
    # 端末やテストを指定したときは、その端末で確かめたいので、枠を取らずに手元で走らせる
    if [[ -n "$sim$only" ]]; then
        exec make --no-print-directory "$target-here"
    fi
    run_in_free_slot "$target" "$front"
}

valid_target() {
    case "$1" in
        check | test | check-test) ;;
        *)
            echo "error: 走らせられないターゲットです: $1" >&2
            exit 1
            ;;
    esac
}

common_dir() {
    git rev-parse --path-format=absolute --git-common-dir
}

# 手元の枠のロックと順番札を置くフォルダー
slots_dir() {
    echo "$(common_dir)/scia-test-slots"
}

# 別のMac、手元の順に、空いている枠で走らせる。どちらも満杯なら、先着順に、先に空いたほうで走らせる。走らせた結果の終了コードで終わる
run_in_free_slot() {
    local target=$1 front=$2 waiting ticket i status quiet='' shown='' local_only=''
    waiting=$(slots_dir)/waiting
    mkdir -p "$waiting"
    ticket=$(new_ticket "$waiting" "$front")
    trap 'rm -f "$ticket"' EXIT
    trap 'stop_child 129' HUP
    trap 'stop_child 130' INT
    trap 'stop_child 143' TERM
    while true; do
        # 受け付けられたあとに中断されたら、札を外したあとなので、同じ名前で置き直して元の順番に戻る
        : > "$ticket"
        if [[ "$(first_ticket "$waiting")" == "$ticket" ]]; then
            if [[ -z "$local_only" ]]; then
                status=0
                # 後ろで走らせる。前で走らせると、終わるまで止める合図を扱えない。呼び出し元がプロセスグループへ送る合図が、依頼の取り消しより先にsshを止めないよう、グループを分ける
                starting=1
                set -m
                SCIA_REMOTE_TICKET=$ticket SCIA_REMOTE_QUIET=$quiet "$0" remote "$target" &
                child=$!
                set +m
                child_started
                wait "$child" || status=$?
                child=
                [[ "$status" == "$UNREACHABLE" || "$status" == "$NOT_ACCEPTED" ]] || exit "$status"
                quiet=1
                # 札が外れているのは、受け付けられたあとで中断されたとき。手元で最初から走らせ直す
                [[ -e "$ticket" ]] || local_only=1
            fi
            for ((i = 1; i <= LOCAL_SLOTS; i++)); do
                exec 8> "$(slots_dir)/local-$i.lock"
                if lockf -s -t 0 8; then
                    rm -f "$ticket"
                    run_here "$target"
                fi
                exec 8>&-
            done
        fi
        if [[ -z "$shown" ]]; then
            echo "別のMacと手元の枠が空くのを待ちます" >&2
            shown=1
        fi
        sleep "$POLL_SECONDS"
    done
}

# 順番札のパスを出す。札の名前は「番号-プロセスID」で、番号の順に走る。frontなら番号を0にして、ほかの札より前に並ぶ。番号を取る間はほかの依頼と重ねない
new_ticket() {
    local seq=0
    if [[ -z "$2" ]]; then
        exec 9> "$1/.lock"
        lockf -s 9
        seq=$(($(cat "$1/.seq" 2>/dev/null || echo 0) + 1))
        echo "$seq" > "$1/.seq"
        exec 9>&-
    fi
    printf '%s/%010d-%d' "$1" "$seq" "$$"
}

# 順番札のうち一番前のものを出す。消えたプロセスの札は消す
first_ticket() {
    local ticket command
    for ticket in "$1"/*; do
        [[ -e "$ticket" ]] || continue
        command=$(ps -p "${ticket##*-}" -o command= 2>/dev/null) || command=
        if [[ "$command" == *test-dispatch.sh* ]]; then
            echo "$ticket"
            return
        fi
        rm -f "$ticket"
    done
}

# 別のMacに、今の作業ツリーのtreeを送って1回依頼する。設定はworktreeどうしで共有する.gitの共通ディレクトリのscia-remote-test.confに置く
remote() {
    local target=$1 conf tree status=0 worker
    valid_target "$target"
    # 枠を待って何度も試すときは、受け付けられない理由を毎回出さない
    [[ -z "${SCIA_REMOTE_QUIET:-}" ]] || exec 2>/dev/null
    conf="$(common_dir)/scia-remote-test.conf"
    if [[ "${SCIA_REMOTE_TEST:-}" == local || ! -f "$conf" ]]; then
        exit "$NOT_ACCEPTED"
    fi
    # shellcheck disable=SC1090
    source "$conf"
    : "${SCIA_REMOTE_HOST:?scia-remote-test.confにSCIA_REMOTE_HOSTを書く}"
    : "${SCIA_REMOTE_KEY:?scia-remote-test.confにSCIA_REMOTE_KEYを書く}"
    : "${SCIA_REMOTE_SIMS:?scia-remote-test.confにSCIA_REMOTE_SIMSを書く}"
    ssh_args=(-i "$SCIA_REMOTE_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5)

    if ! ssh "${ssh_args[@]}" "$SCIA_REMOTE_HOST" true 2>/dev/null; then
        echo "$SCIA_REMOTE_HOST に届きません" >&2
        exit "$UNREACHABLE"
    fi

    tree=$(Tools/check-stamp.sh tree)
    worker=$(base64 < Tools/remote-test-worker.sh | tr -d '\n')
    echo "make $target を $SCIA_REMOTE_HOST に依頼します（tree ${tree:0:12}）" >&2

    id=$(uuidgen)
    pipeline=
    # 走らせているほかの依頼を止めないよう、依頼ごとのIDで止める。取り消しが届かなければ、手元のsshを止めて待ちを終える
    cancel() {
        ssh "${ssh_args[@]}" "$SCIA_REMOTE_HOST" "kill -TERM \"\$(cat ~/scia/jobs/$id.pid)\"" 2>/dev/null || kill "$pipeline" 2>/dev/null || true
        wait "$pipeline" 2>/dev/null || true
        exit "$1"
    }
    trap 'cancel 129' HUP
    trap 'cancel 130' INT
    trap 'cancel 143' TERM
    # 前で走らせると、シェルは終わるまで止める合図を扱わないので、後ろで走らせて待つ
    git archive "$tree" | ssh "${ssh_args[@]}" "$SCIA_REMOTE_HOST" \
        "/bin/bash -c \"\$(echo $worker | base64 -d)\" remote-test-worker $target $tree $id$(printf ' %q' "${SCIA_REMOTE_SIMS[@]}")" > >(release_ticket_on_acceptance) &
    pipeline=$!
    wait "$pipeline" || status=$?
    trap - HUP INT TERM

    case "$status" in
        0)
            remember "$target" "$tree"
            ;;
        "$NOT_ACCEPTED")
            exit "$NOT_ACCEPTED"
            ;;
        255)
            echo "error: 走らせている間に $SCIA_REMOTE_HOST との接続が切れました" >&2
            exit "$UNREACHABLE"
            ;;
        *)
            fetch_failed_results || true
            exit 2
            ;;
    esac
}

# 落ちた回のxcresultを別のMacから手元のDerivedData/test-logsへ運ぶ。受け取れなくてもテストの結果は「落ちた」のままなので、失敗しても終了コードに影響させない
fetch_failed_results() {
    local results="~/scia/results/$id" dest=DerivedData/test-logs names name
    names=$(results_ssh "ls $results 2>/dev/null") || return 0
    [[ -n "$names" ]] || return 0
    mkdir -p "$dest"
    if ! results_ssh "tar -c -C $results ." | tar -x -C "$dest"; then
        echo "落ちた回のxcresultを受け取れませんでした。$SCIA_REMOTE_HOST の $results に残っています" >&2
        return 1
    fi
    results_ssh "rm -rf $results" || true
    for name in $names; do
        echo "落ちた回のxcresultは${PWD}/${dest}/${name}に受け取りました"
    done
}

# 接続が固まってmainへ入れる列を止めないよう、応答がなくなったら諦める
results_ssh() {
    ssh "${ssh_args[@]}" -o ServerAliveInterval=10 -o ServerAliveCountMax=3 "$SCIA_REMOTE_HOST" "$@"
}

# 別のMacが受け付けて最初の行を書いたら、順番札を外して次の依頼に番を譲る
release_ticket_on_acceptance() {
    local line
    if IFS= read -r line; then
        [[ -z "${SCIA_REMOTE_TICKET:-}" ]] || rm -f "$SCIA_REMOTE_TICKET"
        echo "$line"
        cat
    fi
}

# 通ったtreeを手元に覚える。別のMacは送ったtreeと同じ中身で走らせたので、走らせている間に手元を変えていても、このtreeは通っている
remember() {
    local target=$1 tree=$2 kind kinds
    case "$target" in
        check-test) kinds="check test" ;;
        *) kinds=$target ;;
    esac
    for kind in $kinds; do
        Tools/check-stamp.sh record-remote "$kind" "$tree"
    done
}

# 手元の枠のロック（ファイル記述子8）を持った状態で走らせ、その終了コードで終わる
run_here() {
    local target=$1 status=0 acquired lent sim held=''
    if [[ "$target" == check ]]; then
        echo "make check を手元で走らせます"
        run_step make --no-print-directory check-here || status=$?
        exit "$status"
    fi
    # 端末を借りている間にアプリのコンパイルを待たないよう、借りる前にビルドしておく。make check-testの中のビルドは、そのあとでは差分がないので数秒で済む
    if [[ "$target" == check-test ]]; then
        run_step make --no-print-directory build || exit "$?"
    fi
    # このworktreeが借りていた端末は、貸し出しの期限を延ばすだけで、走らせたあとも返さない
    held=$(Tools/sim.sh leased --numbered 2> /dev/null) || held=
    # 借り終えてから記録するまでの間に止められても返せるよう、借り始める前に記録する。借りていないときのreleaseは何もしない
    [[ -n "$held" ]] || borrowed=1
    acquired=$(mktemp)
    run_step Tools/sim.sh acquire --wait 0 > "$acquired" || status=$?
    lent=$(tail -1 "$acquired")
    rm -f "$acquired"
    if [[ "$status" != 0 ]]; then
        echo "error: make test の端末を借りられませんでした" >&2
        leave_here "$status"
    fi
    sim=${lent% *}
    # 確かめたあとに貸し出しの期限が切れると、別の端末を新しく借りていることがある
    if [[ "$sim" != "$held" ]]; then
        held=
        borrowed=1
    fi
    # ほかのworktreeが使ったあとの端末は、その設定やチューニングを持ち込まないよう、既定に戻してからテストする
    if [[ -z "$held" && "${lent##* }" != ready ]]; then
        run_step Tools/sim.sh reset "$sim" || status=$?
        if [[ "$status" != 0 ]]; then
            echo "error: $sim の設定を戻せませんでした" >&2
            leave_here "$status"
        fi
    fi
    echo "make $target を $sim で走らせます"
    run_step make --no-print-directory "$target-here" SIM="$sim" || status=$?
    leave_here "$status"
}

# 入口が借りた端末を返して終わる
leave_here() {
    if [[ -n "$borrowed" ]]; then
        Tools/sim.sh release --numbered > /dev/null
        borrowed=
    fi
    exit "$1"
}

# 走らせている子。プロセスグループごと止めるものは、グループを負の番号で持つ
child=
# 子を起動してからchildに覚えるまでの間か。その間に届いた止める合図は、覚えてから扱う。覚える前に扱うと、子を止められないため
starting=
pending_signal=
# 入口が端末を借りたか。止められたときに返す
borrowed=

# 手元の枠のロックを持ったまま、プロセスグループを分けてコマンドを走らせ、終わるまで待つ
# xcodebuildの常駐プロセスが受け継ぐと、終わっても枠が空かないので、子ではロックのファイル記述子を閉じる
run_step() {
    local status=0 pid
    starting=1
    set -m
    "$@" 8>&- &
    pid=$!
    set +m
    child=-$pid
    child_started
    wait "$pid" || status=$?
    child=
    return "$status"
}

child_started() {
    starting=
    [[ -z "$pending_signal" ]] || stop_child "$pending_signal"
}

# 走らせている子へ止める合図を伝えて、シグナルの番号に128を足した終了コードで終わる
stop_child() {
    if [[ -n "$starting" ]]; then
        pending_signal=$1
        return
    fi
    if [[ -n "$child" ]]; then
        kill -TERM -- "$child" 2>/dev/null || true
        wait 2>/dev/null || true
        # 直接の子が終わっても孫が終わる処理を続けていることがあり、その間に端末を返すと重なるので、グループが空になるまで待つ
        if [[ "$child" == -* ]]; then
            while pgrep -g "${child#-}" > /dev/null; do
                sleep 0.2
            done
        fi
    fi
    [[ -z "$borrowed" ]] || Tools/sim.sh release --numbered > /dev/null || true
    exit "$1"
}

case "${1:-}" in
    dispatch)
        shift
        dispatch "$@"
        ;;
    remote)
        remote "${2:?check、test、check-testのどれかを渡す}"
        ;;
    *)
        echo "使い方: Tools/test-dispatch.sh dispatch <target> '<SIM>' '<ONLY>' [front] | remote <target>" >&2
        exit 1
        ;;
esac
