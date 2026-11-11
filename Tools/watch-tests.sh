#!/bin/bash
# make testの間、あとから調べるための記録を残す。Makefileのtest-on-simが後ろで起動し、テストが終わったら止める。
# load.log: 5秒ごとの時刻、ロードアベレージ、動いているxcodebuildとswift-frontendの数
# <テストの名前>-<ハッシュ>.sample.txt: 始まってからWATCH_SLOW_SECONDS秒（既定は30秒）たっても終わらないSciaCoreのテストの、実行プロセスのスタック。テストごとに1回だけ取り、末尾にテストの名前を書く
# 使い方: Tools/watch-tests.sh <SciaCoreTestsの出力のファイル> <書き出すフォルダー> <端末の名前>

log=$1
out=$2
sim=$3
slow=${WATCH_SLOW_SECONDS:-30}
mkdir -p "$out"
started="$out/.started"
: > "$started"

# ログの中で、始まってまだ終わっていないテストの名前を出す。テストケースごとの行とテストの実行全体の行は数えない。
running_tests() {
    awk '
        { line = $0 }
        /◇ Test / && !/◇ Test (case|run) / { sub(/.*◇ Test /, "", line); split(line, parts, " "); running[parts[1]] = 1 }
        /(✔|✘|━) Test / && / (passed|failed) after / { sub(/.*(✔|✘|━) Test /, "", line); split(line, parts, " "); delete running[parts[1]] }
        END { for (name in running) print name }
    ' "$log" 2>/dev/null
}

# この端末で動いているテストの実行プロセス。ほかのworktreeのテストのものを取らないよう、端末のlaunchd_simの子から探す。
xctest_pid() {
    local udid launchd
    udid=$(xcrun simctl list devices | grep -F "$sim (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
    launchd=$(pgrep -f "launchd_sim .*$udid" | head -1)
    [ -n "$launchd" ] && pgrep -x -P "$launchd" xctest | tail -1
}

sample_slow_tests() {
    local now=$1 name first file pid
    running_tests | while IFS= read -r name; do
        first=$(awk -v name="$name" '$2 == name { print $1; exit }' "$started")
        if [ -z "$first" ]; then
            echo "$now $name" >> "$started"
            continue
        fi
        # 日本語の名前は記号と同じ扱いで潰れて重なるので、名前のハッシュを足して分ける。
        file="$out/${name//[^A-Za-z0-9_]/_}-$(printf '%s' "$name" | shasum | cut -c1-8).sample.txt"
        [ $(( now - first )) -ge "$slow" ] && [ ! -e "$file" ] || continue
        pid=$(xctest_pid)
        [ -n "$pid" ] && sample "$pid" 3 -file "$file" >/dev/null 2>&1 && echo "test: $name" >> "$file"
    done
}

# 止める合図（TERM）は、取っている途中のスタックを書き終えてから受ける。bashは、前で走っているコマンドが終わるまでtrapを走らせないので、
# 待ちだけを後ろに回して、待ちの間に来た合図はすぐ受ける。起動した側は、止めたあとにこの処理の終わりを待ってから、書き出したフォルダーをコピーする
sleeper=
trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM

while :; do
    now=$(date +%s)
    echo "$(date '+%Y-%m-%d %H:%M:%S') $(sysctl -n vm.loadavg) xcodebuild=$(pgrep -x xcodebuild | wc -l | tr -d ' ') swift-frontend=$(pgrep -x swift-frontend | wc -l | tr -d ' ')" >> "$out/load.log"
    sample_slow_tests "$now"
    sleep 5 & sleeper=$!
    wait "$sleeper"
done
