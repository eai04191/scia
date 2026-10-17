#!/bin/bash
# agentがシミュレーターを見るための道具。画像を小さく撮り、画面が止まってから撮り、画面の要素を文字で取り出す。
# 使い方:
#   Tools/sim.sh shot '<端末>' [--width <px>] [--crop <x>,<y>,<w>,<h>] [--out <ファイル>] [--full <ファイル>] [--no-settle]
#     画面が止まるまで待ってから撮り、縮小したJPEGのパスを出す。--widthの既定は端末のポイント幅で、画像の1pxがタップの1ptになる。
#     --cropはポイントで指定し、切り出した範囲だけを同じ倍率で出す（座標は切り出した左上からになる）。
#     --fullを付けると、ユーザーに送るための原寸のPNGも残す。
#   Tools/sim.sh settle '<端末>'
#     画面が止まるまで待つ。撮らずに待ちたいとき（操作の直後にdumpする前など）に使う。
#   Tools/sim.sh dump '<端末>' [--settle]
#     起動済みのアプリに`scia-debug://dump`を送り、画面にある要素の名前と枠（ポイント）を出す。--settleを付けると、画面が止まってから出す。
set -euo pipefail

BUNDLE_ID=net.mizle.scia
# 画面が止まったとみなすまでの上限。動画の再生中など、止まらない画面ではこの時間で諦めて、止まっていないと出す。
SETTLE_TIMEOUT=${SETTLE_TIMEOUT:-6}

fail() {
    echo "sim.sh: $*" >&2
    exit 1
}

# 呼び出しごとに別のフォルダーを作る。別のスレッドが別の端末で同時に撮っても、画像を取り違えないようにする。
# 出した画像は後から読むので消さない。TMPDIRの中なので、OSが古いものを片付ける。
work_dir() {
    local dir="${TMPDIR:-/tmp}"; dir="${dir%/}/scia-sim"
    mkdir -p "$dir"
    mktemp -d "$dir/$(date +%H%M%S).XXXX"
}

# 端末の画面の倍率（ポイントあたりのピクセル）。端末の種類のprofile.plistから読む。
screen_scale() {
    local sim=$1 type_id bundle
    type_id=$(xcrun simctl list devices -j | /usr/bin/python3 -I -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == name or d["udid"] == name:
            print(d["deviceTypeIdentifier"]); sys.exit()
' "$sim")
    [ -n "$type_id" ] || fail "端末が見つからない: $sim"
    bundle=$(xcrun simctl list devicetypes -j | /usr/bin/python3 -I -c '
import json, sys
for t in json.load(sys.stdin)["devicetypes"]:
    if t["identifier"] == sys.argv[1]:
        print(t["bundlePath"]); sys.exit()
' "$type_id")
    [ -n "$bundle" ] || fail "端末の種類が見つからない: $type_id"
    /usr/bin/python3 -I -c '
import plistlib, sys
def find(node):
    if isinstance(node, dict):
        if "ArtworkDeviceScaleFactor" in node:
            return node["ArtworkDeviceScaleFactor"]
        node = list(node.values())
    if isinstance(node, list):
        for child in node:
            found = find(child)
            if found is not None:
                return found
with open(sys.argv[1], "rb") as f:
    scale = find(plistlib.load(f))
if scale is None:
    sys.exit("ArtworkDeviceScaleFactorがない")
print(int(scale))
' "$bundle/Contents/Resources/capabilities.plist"
}

capture() {
    xcrun simctl io "$1" screenshot --type=png "$2" >/dev/null 2>&1 || fail "撮影できない: $1"
}

# 縮小した画像のハッシュ。時計の数字の変化などの細かい差を無視するため、小さくしてから比べる。
fingerprint() {
    local small="$1.small.png"
    sips -Z 96 "$1" --out "$small" >/dev/null 2>&1
    md5 -q "$small"
}

# 続けて撮った2枚が同じになるまで撮り直す。最後に撮ったファイルのパスを残し、止まったかどうかを返す。
settle() {
    local sim=$1 out=$2 previous="" current started
    started=$(date +%s)
    while true; do
        capture "$sim" "$out"
        current=$(fingerprint "$out")
        if [ "$current" = "$previous" ]; then
            return 0
        fi
        if [ $(( $(date +%s) - started )) -ge "$SETTLE_TIMEOUT" ]; then
            return 1
        fi
        previous=$current
    done
}

command_shot() {
    local sim=$1
    shift
    local width="" crop="" out="" full="" do_settle=1
    while [ $# -gt 0 ]; do
        case $1 in
            --width) width=$2; shift 2 ;;
            --crop) crop=$2; shift 2 ;;
            --out) out=$2; shift 2 ;;
            --full) full=$2; shift 2 ;;
            --no-settle) do_settle=0; shift ;;
            *) fail "知らない引数: $1（保存先は--out、原寸の保存先は--fullで指定する）" ;;
        esac
    done
    local dir raw scale stable="止まった" started
    dir=$(work_dir)
    raw="$dir/raw.png"
    started=$(/usr/bin/python3 -I -c 'import time; print(time.time())')
    if [ $do_settle = 1 ]; then
        settle "$sim" "$raw" || stable="止まっていない（${SETTLE_TIMEOUT}秒で諦めた）"
    else
        capture "$sim" "$raw"
        stable="待っていない"
    fi
    [ -z "$full" ] || cp "$raw" "$full"
    scale=$(screen_scale "$sim")
    local pixel_width pixel_height
    pixel_width=$(sips -g pixelWidth "$raw" | awk '/pixelWidth/ {print $2}')
    pixel_height=$(sips -g pixelHeight "$raw" | awk '/pixelHeight/ {print $2}')
    local point_width=$(( pixel_width / scale )) point_height=$(( pixel_height / scale ))
    local source=$raw origin="0,0"
    if [ -n "$crop" ]; then
        local x y w h
        IFS=, read -r x y w h <<<"$crop"
        source="$dir/crop.png"
        sips -c $(( h * scale )) $(( w * scale )) --cropOffset $(( y * scale )) $(( x * scale )) "$raw" --out "$source" >/dev/null
        point_width=$w
        point_height=$h
        origin="$x,$y"
    fi
    [ -n "$width" ] || width=$point_width
    [ -n "$out" ] || out="$dir/shot.jpg"
    sips -s format jpeg -s formatOptions 70 --resampleWidth "$width" "$source" --out "$out" >/dev/null
    local ratio elapsed
    ratio=$(/usr/bin/python3 -I -c "print(round($point_width / $width, 3))")
    elapsed=$(/usr/bin/python3 -I -c "import time; print(round(time.time() - $started, 1))")
    echo "$out"
    echo "画面: $stable（${elapsed}秒） 画像: ${width}px幅 画像の1px = ${ratio}pt 左上 = (${origin})pt"
    [ -z "$full" ] || echo "原寸: $full"
}

command_settle() {
    local dir started elapsed
    dir=$(work_dir)
    started=$(/usr/bin/python3 -I -c 'import time; print(time.time())')
    if settle "$1" "$dir/raw.png"; then
        elapsed=$(/usr/bin/python3 -I -c "import time; print(round(time.time() - $started, 1))")
        echo "画面: 止まった（${elapsed}秒）"
    else
        echo "画面: 止まっていない（${SETTLE_TIMEOUT}秒で諦めた）"
    fi
}

command_dump() {
    local sim=$1 container file deadline
    [ "${2:-}" != --settle ] || command_settle "$sim"
    # アプリは起動時に、この設定を見てアクセシビリティの要素を作るかを決める。ないとボタンやタブの名前が取れない。
    # VoiceOverは動かないが、要素を作るぶんアプリが少し重くなるので、hitchを測るときは`defaults delete`で外す。
    if [ "$(xcrun simctl spawn "$sim" defaults read com.apple.Accessibility ApplicationAccessibilityEnabled 2>/dev/null)" != 1 ]; then
        xcrun simctl spawn "$sim" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
        fail "アクセシビリティの要素を作る設定を入れた。アプリを起動し直してからもう一度dumpする"
    fi
    container=$(xcrun simctl get_app_container "$sim" "$BUNDLE_ID" data 2>/dev/null) || fail "アプリが入っていない: $sim"
    file="$container/Documents/AgentDump/screen.txt"
    rm -f "$file"
    xcrun simctl openurl "$sim" 'scia-debug://dump'
    deadline=$(( $(date +%s) + 5 ))
    while [ ! -f "$file" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "書き出されない。アプリが起動していないか、デバッグビルドでない"
        sleep 0.1
    done
    cat "$file"
}

[ $# -ge 2 ] || fail "使い方: Tools/sim.sh shot|settle|dump '<端末>' [オプション]"
subcommand=$1
shift
case $subcommand in
    shot) command_shot "$@" ;;
    settle) command_settle "$1" ;;
    dump) command_dump "$@" ;;
    *) fail "知らない操作: $subcommand" ;;
esac
