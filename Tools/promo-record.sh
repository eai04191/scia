#!/bin/bash
# プロモーション動画の素材を、シナリオのUIテストを走らせながら撮る（docs/promo-video.md）。
# 使い方:
#   Tools/promo-record.sh '<端末の名前>' <シナリオのテスト> <出力の.mp4>
#     例: Tools/promo-record.sh 'Scia 1' StreamingDemoUITests/testStreamingDemo promo.mp4
#     素材にするのは、シナリオが録画を始めてから止めるまでの間。Config/Promo.xcconfigで、いつものSciaとは別のアプリとしてビルドして入れる。
#   シミュレーター: `simctl io recordVideo`で撮り、シナリオが画面に一瞬出す始めと終わりの目印で切り出す。
#     simctlは画面が変わったコマだけを、画面の更新どおりに書くので、動きが正確に残る。画面がしばらく変わらないとその間の時間が消えるので、
#     撮影モードのアプリは画面の隅の1点を毎コマわずかに変え続ける（ScenarioHeartbeat）。
#     sim-useの`record-video`は、画面の更新と別の間隔で取り込み、同じ絵を2回撮ったり1つ飛ばしたりして、スワイプした動きが不ぞろいになったので使わない。
#     録画の間はステータスバーを9:41、電波と電池を満タンに、外観をライトにし、終わったら戻す。止まっていたら起動して待つ。
#   実機: アプリがReplayKitで自分の画面を撮り、書き出したファイルを取り出す。ステータスバーは写らない。外観は変えられないので、端末の設定のまま撮る。
set -euo pipefail

BUNDLE_ID=net.mizle.scia.promo

fail() {
    echo "promo-record.sh: $*" >&2
    exit 1
}

[ $# -eq 3 ] || fail "使い方: Tools/promo-record.sh '<端末の名前>' <シナリオのテスト> <出力の.mp4>"
device=$1
test_name=$2
output=$3
# いつものビルドと成果物を上書きし合わないよう、分ける。
derived_data=DerivedData/Promo
xcconfig=Config/Promo.xcconfig
test_log=$(mktemp)

run_test() {
    local destination=$1
    shift
    xcodebuild -project Scia.xcodeproj -scheme SciaPromo -xcconfig "$xcconfig" -destination "$destination" -derivedDataPath "$derived_data" "$@" \
        -collect-test-diagnostics never test-without-building -only-testing:"SciaUITests/$test_name" >"$test_log" 2>&1 \
        || { tail -30 "$test_log" >&2; fail "シナリオが失敗した。全体は$test_log"; }
}

# 録画の中から、シナリオが画面に一瞬出す目印（マゼンタ、ScenarioMarker）のコマを探し、
# 1つ目の目印が消えた時刻と、2つ目の目印が出た時刻を「<始め> <終わり>」の形で出す。
# 録画は画面がしばらく変わらないとその間の時間が消え、Macの時計と合わなくなることがあるので、時計ではなく録画の中の目印で決める。
find_markers() {
    ffmpeg -v error -i "$1" -vf "crop=200:200:500:1200,signalstats,metadata=print:file=-" -f null - |
        awk '
            /pts_time:/ { split($0, field, "pts_time:"); time = field[2] + 0 }
            /lavfi.signalstats.UAVG=/ { split($0, field, "="); u = field[2] + 0 }
            /lavfi.signalstats.VAVG=/ {
                split($0, field, "="); v = field[2] + 0
                marked = (u > 180 && v > 200)
                if (marked && !inside) { inside = 1; runs++; if (runs == 2) end = time }
                if (!marked && inside) { inside = 0; if (runs == 1) start = time }
            }
            END { if (start != "" && end != "") print start, end }
        '
}

record_simulator() {
    local destination="platform=iOS Simulator,name=$device"
    xcrun simctl bootstatus "$device" -b >/dev/null
    xcodebuild -project Scia.xcodeproj -scheme SciaPromo -xcconfig "$xcconfig" -destination "$destination" -derivedDataPath "$derived_data" build-for-testing -quiet

    local appearance raw recorder_log
    recorder=
    # 外観が自動で切り替わる端末でも、撮る時刻で見た目が変わらないようにする。
    appearance=$(xcrun simctl ui "$device" appearance)
    raw=$(mktemp -d)/raw.mov
    recorder_log=$(mktemp)

    # 途中で失敗しても、録画を閉じ、ステータスバーと外観を戻す。
    restore() {
        if [ -n "$recorder" ]; then
            # SIGINTで止めると、録画中のコマを書き終えてからファイルを閉じる。
            kill -INT "$recorder" 2>/dev/null || true
            wait "$recorder" 2>/dev/null || true
            recorder=
        fi
        xcrun simctl status_bar "$device" clear
        xcrun simctl ui "$device" appearance "$appearance"
    }
    trap restore EXIT

    xcrun simctl ui "$device" appearance light
    xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
    xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl io "$device" recordVideo --codec=h264 --force "$raw" 2>"$recorder_log" &
    recorder=$!
    # 録画が始まるのを待つ。始まると、simctlが「Recording started」と書く。素材の範囲は目印で決めるので、ここでは始まったことだけを確かめる。
    for _ in $(seq 1 100); do
        grep -q "Recording started" "$recorder_log" && break
        sleep 0.05
    done
    grep -q "Recording started" "$recorder_log" || fail "録画が始まらない: $(cat "$recorder_log")"

    run_test "$destination"
    restore
    trap - EXIT

    local markers start end
    markers=$(find_markers "$raw")
    [ -n "$markers" ] || fail "録画の中に、始めと終わりの目印が見つからない。元の録画は$raw"
    read -r start end <<<"$markers"
    # 録画は画面が変わったときだけコマを書き、数ms差で続けて書くこともあるので、編集で扱いやすい一定の60fpsにそろえて切り出す。
    # 時刻をそのまま持ち込むと、同じ時刻や前後した時刻のコマが並び、平均のfpsから決めた粗い刻みに丸められてカクついて見えた。
    # 切る位置を先に探すと、近くの区切りのコマへずれることがあるので、頭から読んで切る。
    ffmpeg -v error -y -i "$raw" -ss "$start" -to "$end" \
        -vf fps=60 -c:v libx264 -preset slow -crf 12 -pix_fmt yuv420p -an "$output"
}

record_device() {
    local udid=$1
    local destination="platform=iOS,id=$udid"
    xcodebuild -project Scia.xcodeproj -scheme SciaPromo -xcconfig "$xcconfig" -destination "$destination" -derivedDataPath "$derived_data" -allowProvisioningUpdates build-for-testing -quiet
    run_test "$destination" -allowProvisioningUpdates
    xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source Documents/Promo/promo.mp4 --destination "$output" >/dev/null
}

if xcrun simctl list devices | grep -q "    $device ("; then
    record_simulator
else
    udid=$(xcrun devicectl list devices 2>/dev/null | awk -v name="$device" 'index($0, name " ") == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i }')
    [ -n "$udid" ] || fail "端末が見つからない: $device"
    record_device "$udid"
fi
echo "素材: $output（シナリオの記録は$test_log）"
