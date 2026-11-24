#!/bin/bash
# コマンドを走らせ、テストを動かすプロセスが現れてからTEST_RUN_LIMIT秒（既定は60秒）たっても残っていれば、固まったとみなす。
# 固まったら、このworktreeのテストのプロセスと、その子のプロセス（テストがforkしたもの）のスタックを出力に出し、止めて124で終わる。
# GitHub Actionsでは、jobの上限まで待たずに、どこで止まったかをjobのログに残すために使う。
# テストのプロセスが落ちたら、そのクラッシュレポートをDerivedData/test-logsにコピーする。
# テストの出力は、パイプやファイルに流すと溜めてから書かれ、少ないうちは出てこないので、出力が増えるかでは判断しない。
# 使い方: Tools/watch-release-test.sh <コマンド> [引数...]
set -u

limit=${TEST_RUN_LIMIT:-60}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/DerivedData/test-logs"
log=$(mktemp "$root/DerivedData/test-logs/release.log.XXXXXX") || exit $?
sw_vers > "$log.environment.txt"
xcodebuild -version >> "$log.environment.txt"
uname -m >> "$log.environment.txt"

"$@" > "$log" 2>&1 &
command_pid=$!
tail -n +1 -f "$log" &
tail_pid=$!

# このworktreeのパッケージのテストを動かしているプロセス。ほかのworktreeのものと、ビルドのプロセスは取らない。
test_roots() {
    pgrep -f "(swiftpm-testing-helper|xctest) .*$root/Packages/[^ ]*/\.build/"
}

# テストを動かしているプロセスと、その子。
test_pids() {
    local pid
    for pid in $(test_roots); do
        echo "$pid"
        pgrep -P "$pid"
    done | sort -u
}

dump_and_stop() {
    local pid
    echo "::group::固まったテストのプロセス"
    ps -axo pid,ppid,state,%cpu,rss,etime,command | grep -F "$root" | grep -v grep
    echo "::endgroup::"
    for pid in $(test_pids); do
        echo "::group::sample $pid"
        sample "$pid" 3 -mayDie 2>&1 | sed -n '/^Call graph:/,/^Total number in stack/p'
        echo "::endgroup::"
    done
    for pid in $(test_pids); do
        kill -KILL "$pid" 2>/dev/null
    done
    kill "$command_pid" 2>/dev/null
}

# テストのプロセスが落ちたとき、落ちた呼び出しのスタックを残すため、走らせてから書かれたクラッシュレポートをtest-logsへコピーする。
# レポートはプロセスが終わったあとに書かれるので、60秒待ってから集める。
# CrashMarkTestsがforkした子をわざと落とし、同じ名前のレポートが先にできるので、最初のレポートが現れた時点では止めない。
copy_crash_reports() {
    local reports=$HOME/Library/Logs/DiagnosticReports
    local found
    sleep 60
    found=$(find "$reports" -maxdepth 1 -name '*.ips' -newer "$log.environment.txt" \( -name 'swiftpm-testing-helper*' -o -name 'xctest*' -o -name '*Tests*' \) 2>/dev/null)
    if [ -z "$found" ]; then
        echo "テストのプロセスが落ちましたが、クラッシュレポートは見つかりませんでした"
        return
    fi
    echo "$found" | while read -r report; do
        cp "$report" "$root/DerivedData/test-logs/"
        echo "クラッシュレポートを保存しました: $(basename "$report")"
    done
}

# パッケージごとにテストのプロセスが現れてから測る。ビルドの間は測らない。
# 見張りの間隔のうちに次のパッケージのテストへ替わっても測り直すよう、テストのプロセスのIDが替わったら測り直す。
running=
running_since=
while kill -0 "$command_pid" 2>/dev/null; do
    sleep 5
    current=$(test_roots | sort | tr '\n' ' ')
    if [ -z "$current" ]; then
        running=
        continue
    fi
    if [ "$current" != "$running" ]; then
        running=$current
        running_since=$SECONDS
    fi
    if [ $(( SECONDS - running_since )) -ge "$limit" ]; then
        sleep 1
        kill "$tail_pid" 2>/dev/null
        echo "テストを動かすプロセスが${limit}秒たっても終わらないので、固まったとみなしてスタックを出します"
        dump_and_stop
        wait "$command_pid" 2>/dev/null
        exit 124
    fi
done

wait "$command_pid"
status=$?
sleep 1
kill "$tail_pid" 2>/dev/null
if grep -q "exited with unexpected signal" "$log"; then
    copy_crash_reports
fi
exit "$status"
