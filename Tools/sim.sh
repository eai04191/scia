#!/bin/bash
# agentがシミュレーターを見るための道具。画像を小さく撮り、画面が止まってから撮り、画面の要素を文字で取り出す。
# 使い方:
#   Tools/sim.sh shot '<端末>' [--width <px>] [--crop <x>,<y>,<w>,<h>] [--out <ファイル>] [--full <ファイル>] [--no-settle]
#     画面が止まるまで待ってから撮り、縮小したJPEGのパスを出す。--widthの既定は端末のポイント幅で、画像の1pxがタップの1ptになる。
#     --cropはポイントで指定し、切り出した範囲だけを同じ倍率で出す（座標は切り出した左上からになる）。
#     --fullを付けると、ユーザーに送るための原寸のPNGも残す。
#   Tools/sim.sh drag <x1> <y1> <x2> <y2>
#     慣性を残さずに止まるドラッグの点の並びを、シミュレーターのツールのtouch_pathのpointsに渡せるJSONで出す。
#     ツールのtouch_pathは同じ座標の点を「動いた」として送らないため、最後に同じ点を並べても離した瞬間の速さが残り、慣性で流れる。
#     そこで、終点で0.5ptずつ揺らして速さを0にしてから離す。最初の一歩（20pt）は、スクロールが始まるまでの遊びに吸われるので、
#     一覧をDだけ動かしたいときは、指をD+20pt動かす。
#   Tools/sim.sh dump '<端末>'
#     起動済みのアプリに`scia-debug://dump`を送り、画面にある要素の名前と枠（ポイント）を出す。
#     アプリの中で、アニメーションとスクロールの慣性が止まるのを待ってから書き出すので、操作の直後に呼んでよい。
#   Tools/sim.sh reset '<端末>'
#     アプリを終了し、アプリの設定（設定、チューニング、デバッグ用の値）を既定に戻す。端末を割り当てられたときに走らせ、
#     前に使ったスレッドが確かめのために変えた値を持ち込まない。アカウントの並びと使うアカウント、アカウントやサーバーごとに覚えた値は残す。
#   Tools/sim.sh busy '<端末>'
#     その端末の名前かUDIDをコマンドラインに含む処理（make test、xcodebuild、simctl、録画など）を探し、どのworktreeのスレッドが起動したかを出す。
#     ターンを返したあともバックグラウンドの処理は走り続けるので、止まっているスレッドの端末を取る前に、使っている処理が残っていないかを確かめる。
#     シミュレーターのツールのタップやスワイプは1回ずつで終わり、処理として残らないので、ここには出ない。
#   Tools/sim.sh acquire [--wait <秒>] ['<端末>']
#     このworktreeに端末を貸す。空きがなければ空くまで待ち（既定は540秒、0なら上限なく待つ）、借りた端末と状態を「Scia 2 ready」の形で出す。
#     readyなら、前にこのworktreeが設定を戻してビルドを入れ、そのあと誰も借りていない。claimedなら、設定を戻してビルドを入れ直し、readyを記録する。
#     すでに借りていれば同じ端末を延ばす。貸し出しは30分で切れるので、長く使うときはacquireし直す。待っても空かなければ終了コード75で終わる。
#   Tools/sim.sh release
#     このworktreeが借りている端末を返す。シミュレーターを触り終えたら、ターンを返す前に返す。
#   Tools/sim.sh ready '<端末>'
#     借りた端末に、設定を戻して自分のビルドを入れ終えたことを記録する。
#   Tools/sim.sh status
#     端末ごとの借り手、最後にビルドを入れたworktree、使っている処理の数を出す。
#   shot、dump、resetは、このworktreeが借りている端末にしか使えない。
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
    require_lease "$sim"
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

command_dump() {
    local sim=$1 container file deadline
    require_lease "$sim"
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
    # アプリは画面が止まるのを最大5秒待ってから書き出す。
    deadline=$(( $(date +%s) + 8 ))
    while [ ! -f "$file" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "書き出されない。アプリが起動していないか、デバッグビルドでない"
        sleep 0.1
    done
    cat "$file"
}

# 既定に戻す設定のキーの頭。アカウントの並び（accounts.）や、アカウントとサーバーごとに覚えた値（account.、server.）は、確かめのために変える設定ではないので残す。
RESET_KEY_PREFIXES='settings. tuning. tuningPanel. debug.'

command_reset() {
    [ $# -eq 1 ] || fail "使い方: Tools/sim.sh reset '<端末>'"
    local sim=$1 container domain keys key
    require_lease "$sim"
    container=$(xcrun simctl get_app_container "$sim" "$BUNDLE_ID" data 2>/dev/null) || fail "アプリが入っていない: $sim"
    # 動いているアプリは、覚えている値を書き戻すことがあるので、先に終了する。起動していなければ失敗するが、構わない。
    xcrun simctl terminate "$sim" "$BUNDLE_ID" >/dev/null 2>&1 || true
    domain="$container/Library/Preferences/$BUNDLE_ID"
    if [ ! -f "$domain.plist" ]; then
        echo "設定はまだない: $sim"
        return
    fi
    # JSONに直さずにplistのまま読む。アカウントごとに覚えた値にはData型があり、`plutil -convert json`はそれで失敗する。
    keys=$(/usr/bin/python3 -I -c '
import plistlib, sys
prefixes = tuple(sys.argv[2].split())
with open(sys.argv[1], "rb") as f:
    for key in plistlib.load(f):
        if key.startswith(prefixes):
            print(key)
' "$domain.plist" "$RESET_KEY_PREFIXES")
    # plistのファイルを直接書き換えると、端末のcfprefsdが覚えている値で書き戻されるので、端末の中のdefaultsで消す。
    # ドメインはアプリのコンテナの中のパスで渡す。`net.mizle.scia`で渡すと、コンテナの外の設定を指してアプリに届かない。
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        xcrun simctl spawn "$sim" defaults delete "$domain" "$key"
    done <<< "$keys"
    echo "設定を既定に戻した（$(grep -c . <<< "$keys" || true)個）: $sim"
}

# 端末の名前かUDIDをコマンドラインに含む処理を、1行ずつ出す。2つ目の引数のworktreeから起動したものは除く。
busy_procs() {
    local sim=$1 exclude=$2 device name udid
    # UDIDで渡されても、名前で走らせた処理（make test SIM='Scia 1'など）を拾えるよう、名前とUDIDの両方を引く。
    device=$(xcrun simctl list devices -j | /usr/bin/python3 -I -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == sys.argv[1] or d["udid"] == sys.argv[1]:
            print(d["udid"], d["name"]); sys.exit()
' "$sim")
    [ -n "$device" ] || fail "端末が見つからない: $sim"
    udid=${device%% *}
    name=${device#* }
    ps -axo pid=,ppid=,command= | /usr/bin/python3 -I -c '
import os, re, subprocess, sys
name, udid, caller, exclude = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
procs = {}
for line in sys.stdin:
    pid, ppid, command = line.strip().split(None, 2)
    procs[int(pid)] = (int(ppid), command)
def ancestors(pid):
    # psが一覧を取ったあとに親が終わると、親の行がない。そこで止める。
    while pid in procs and procs[pid][0] in procs and pid > 1:
        pid = procs[pid][0]
        yield pid
# 呼び出したスレッドのシェルも端末の名前を含むので、このスクリプトと、その祖先と子孫は数えない。
# psがPythonより先に一覧を取ると、Python自身は一覧にないので、スクリプトのシェルのPIDを渡してもらう。
mine = {caller, *ancestors(caller)}
mine |= {pid for pid in procs if caller in ancestors(pid)}
pattern = re.compile(re.escape(name) + r"(?![0-9])|" + re.escape(udid))
agent = re.compile(r"/claude-code/.*/MacOS/claude ")
app = re.compile(r"^/Applications/Claude\.app/Contents/MacOS/Claude\b")
booted = re.compile(r"^launchd_sim ")
# 貸し借りの操作（空きを待っているacquireなど）は、端末名を引数に持つが、端末を触らない。
bookkeeping = re.compile(r"sim\.sh (acquire|release|ready|status|busy|__[a-z_]+)( |$)")
found = []
for pid, (_, command) in procs.items():
    if pid in mine or not pattern.search(command):
        continue
    # 起動している端末の中のプロセス（launchd_simと、その子のアプリなど）も、パスにUDIDを含むが、スレッドの操作ではない。
    if booted.search(command) or any(booted.search(procs[a][1]) for a in ancestors(pid)):
        continue
    if bookkeeping.search(command):
        continue
    owner = None
    for a in ancestors(pid):
        if agent.search(procs[a][1]):
            owner = a; break
        if app.search(procs[a][1]):
            owner = "app"; break
    # Claudeのアプリ本体が直接起動したもの（シミュレーターのパネルが画面の向きを読むlog streamなど）は、スレッドの操作ではない。
    if owner == "app":
        continue
    where = "スレッドの外（ターミナルなど）"
    if owner is not None:
        out = subprocess.run(["lsof", "-a", "-p", str(owner), "-d", "cwd", "-Fn"], capture_output=True, text=True).stdout
        where = next((l[1:] for l in out.splitlines() if l.startswith("n")), "不明")
        # 元のcheckoutの下に.claude/worktrees/のworktreeがあるので、パスの前方一致ではなく、処理のworktreeで比べる。
        top = subprocess.run(["git", "-C", where, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
        if exclude and top == exclude:
            continue
    found.append(f"{pid} {where}: {command[:160]}")
if found:
    print("\n".join(found))
' "$name" "$udid" "$$" "$exclude"
}

command_busy() {
    [ $# -eq 1 ] || fail "使い方: Tools/sim.sh busy '<端末>'"
    local found
    found=$(busy_procs "$1" "")
    if [ -n "$found" ]; then
        echo "使っている処理がある: $1"
        echo "$found"
    else
        echo "使っている処理はない: $1"
    fi
}

command_drag() {
    [ $# -eq 4 ] || fail "使い方: Tools/sim.sh drag <x1> <y1> <x2> <y2>"
    /usr/bin/python3 -I -c '
import json, math, sys
x1, y1, x2, y2 = map(float, sys.argv[1:5])
# 1歩20pt、32ms間隔（約600pt/s）。速すぎると、揺らす前に速さが積み上がる。
steps = max(1, math.ceil(math.hypot(x2 - x1, y2 - y1) / 20))
points = [{"x": x1, "y": y1, "dt_ms": 0}]
for i in range(1, steps + 1):
    points.append({"x": round(x1 + (x2 - x1) * i / steps, 1), "y": round(y1 + (y2 - y1) * i / steps, 1), "dt_ms": 32})
# 終点で16ms ごとに0.5pt揺らし、約250ms止める。
for i in range(16):
    points.append({"x": x2, "y": y2 + (0.5 if i % 2 == 0 else 0), "dt_ms": 16})
print(json.dumps(points, separators=(",", ":")))
' "$@"
}

# 端末の貸し借りの記録。worktreeどうしで共有するgitのディレクトリに置く。
# 並行するスレッドはworktreeを分けるので、借り手はworktreeのパスで表す。スレッドの一覧を読まずに、シェルだけで判断できるようにするため。
lock_root() {
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir) || fail "gitのリポジトリの外で走らせている"
    mkdir -p "$common/sim-locks"
    echo "$common/sim-locks"
}

borrower() {
    git rev-parse --show-toplevel || fail "gitのworktreeの外で走らせている"
}

# 貸す端末。名前が「Scia <番号>」の端末を番号の順に並べる。
pool() {
    xcrun simctl list devices -j | /usr/bin/python3 -I -c '
import json, re, sys
names = [d["name"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if re.fullmatch(r"Scia [0-9]+", d["name"])]
print("\n".join(sorted(set(names), key=lambda n: int(n.split()[1]))))
'
}

# 借りたまま返さずに止まったスレッドのため、この秒数より古い貸し出しは返されたものとして扱う。長く使うときは、acquireし直して延ばす。
LEASE_SECONDS=${LEASE_SECONDS:-1800}

# 貸し出しの記録を読んで書き換える処理は、.guardをlockfで持って1つずつ走らせる。
# 2つのスレッドが同じ端末を空きと見て、両方が借りる入れ違いを起こさないため。
guarded() {
    lockf -k -t 30 "$(lock_root)/.guard" "$0" "$@"
}

# 端末を今借りているworktree。借りられていないか、期限が切れていれば空を出す。
lease_holder() {
    local file="$(lock_root)/$1.lease" holder since
    [ -f "$file" ] || return 0
    read -r since holder < "$file"
    [ $(( $(date +%s) - since )) -le "$LEASE_SECONDS" ] || return 0
    echo "$holder"
}

# 端末に最後に設定を戻してビルドを入れたworktreeと、入れ終えたか（claimed、ready）。
build_state() {
    local file="$(lock_root)/$1.build"
    [ -f "$file" ] && cat "$file"
    return 0
}

# 以下の__で始まる操作は、guardedから.guardを持った状態で呼ばれる。
command___acquire_try() {
    local me=$1 want=${2:-} root sim held='' candidates procs
    root=$(lock_root)
    # すでに借りていれば、同じ端末を延ばす。別の端末を指定されたら、借りていたものを返す。
    while IFS= read -r sim; do
        [ -n "$sim" ] && [ "$(lease_holder "$sim")" = "$me" ] || continue
        if [ -z "$want" ] || [ "$want" = "$sim" ]; then
            held=$sim
        else
            rm -f "$root/$sim.lease"
        fi
    done <<< "$(pool)"
    if [ -n "$held" ]; then
        echo "$(date +%s) $me" > "$root/$held.lease"
        if [ "$(build_state "$held")" = "$me ready" ]; then echo "$held ready"; else echo "$held claimed"; fi
        return 0
    fi
    # 前に自分のビルドを入れ終えた端末を先に試す。入れ直しを省けるため。
    candidates=$( { if [ -n "$want" ]; then echo "$want"; else pool; fi; } | while IFS= read -r sim; do
        if [ "$(build_state "$sim")" = "$me ready" ]; then echo "0 $sim"; else echo "1 $sim"; fi
    done | sort -s -k1,1 | cut -d' ' -f2-)
    while IFS= read -r sim; do
        [ -n "$sim" ] && [ -z "$(lease_holder "$sim")" ] || continue
        # 返したあとも走り続けるバックグラウンドの処理（make test、録画など）が残っていれば、借りられない。
        # 調べられなかったときに、出力が空なのを空きと取り違えないよう、失敗したら止める。
        procs=$(busy_procs "$sim" "$me") || fail "$simを使っている処理を調べられない"
        [ -z "$procs" ] || continue
        echo "$(date +%s) $me" > "$root/$sim.lease"
        if [ "$(build_state "$sim")" = "$me ready" ]; then
            echo "$sim ready"
        else
            echo "$me claimed" > "$root/$sim.build"
            echo "$sim claimed"
        fi
        return 0
    done <<< "$candidates"
    return 75
}

command___release() {
    local me=$1 sim
    while IFS= read -r sim; do
        [ -n "$sim" ] && [ "$(lease_holder "$sim")" = "$me" ] && rm -f "$(lock_root)/$sim.lease"
    done <<< "$(pool)"
    return 0
}

command___ready() {
    local sim=$1 me=$2
    [ "$(lease_holder "$sim")" = "$me" ] || fail "$simを借りていない（借りているもの: $(lease_holder "$sim" | sed 's/^$/なし/')）"
    echo "$me ready" > "$(lock_root)/$sim.build"
}

# 端末を受け取るほかの操作の前に、このworktreeが借りているかを確かめる。借りずに触ると、ほかのスレッドの確かめを乱すため。
require_lease() {
    local sim=$1 holder
    holder=$(lease_holder "$sim")
    [ "$holder" = "$(borrower)" ] || fail "$simを借りていない（借りているもの: ${holder:-なし}）。先にTools/sim.sh acquireで借りる"
}

command_acquire() {
    local wait=540 want='' me out status deadline
    while [ $# -gt 0 ]; do
        case $1 in
            --wait) wait=$2; shift 2 ;;
            *) want=$1; shift ;;
        esac
    done
    [ -z "$want" ] || pool | grep -qxF "$want" || fail "貸す端末にない: $want"
    me=$(borrower)
    # 回数ではなく経過時間で数える。.guardの取り合いでlockfが待つ時間も、上限に含めるため。0なら上限なく待つ。
    deadline=$(( $(date +%s) + wait ))
    while true; do
        status=0
        out=$(guarded __acquire_try "$me" "$want") || status=$?
        if [ "$status" -eq 0 ]; then
            echo "$out"
            return
        fi
        [ "$status" -eq 75 ] || fail "借りられない（終了コード $status）"
        if [ "$wait" -ne 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
            echo "sim.sh: 空いている端末がない。もう一度acquireして待つ" >&2
            command_status >&2
            exit 75
        fi
        sleep 2
    done
}

command_release() {
    guarded __release "$(borrower)"
    echo "返した: $(borrower)"
}

command_ready() {
    [ $# -eq 1 ] || fail "使い方: Tools/sim.sh ready '<端末>'"
    guarded __ready "$1" "$(borrower)"
    echo "入れ終えた: $1"
}

command_status() {
    local sim holder build procs
    while IFS= read -r sim; do
        [ -n "$sim" ] || continue
        holder=$(lease_holder "$sim")
        build=$(build_state "$sim")
        procs=$(busy_procs "$sim" "" | grep -c . || true)
        echo "$sim: 借り手=${holder:-なし} ビルド=${build:-なし} 使っている処理=${procs}件"
    done <<< "$(pool)"
}

[ $# -ge 1 ] || fail "使い方: Tools/sim.sh shot|dump|reset|busy|ready '<端末>' [オプション]、Tools/sim.sh acquire [--wait <秒>] ['<端末>']、Tools/sim.sh release|status、Tools/sim.sh drag <x1> <y1> <x2> <y2>"
subcommand=$1
shift
case $subcommand in
    shot) command_shot "$@" ;;
    dump) command_dump "$@" ;;
    drag) command_drag "$@" ;;
    reset) command_reset "$@" ;;
    busy) command_busy "$@" ;;
    acquire) command_acquire "$@" ;;
    release) command_release "$@" ;;
    ready) command_ready "$@" ;;
    status) command_status "$@" ;;
    __acquire_try) command___acquire_try "$@" ;;
    __release) command___release "$@" ;;
    __ready) command___ready "$@" ;;
    *) fail "知らない操作: $subcommand" ;;
esac
