# setup.sh、reset.sh、run.shが読み込む、シナリオの置き場所と共通の手順。
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 証明書、Mastodonの秘密の値、データ、スナップショット、人として触らせた報告は、リポジトリの外に置く。worktreeを消しても残し、どのworktreeからも同じものを使う
export SCENARIO_HOME="${SCIA_SCENARIO_HOME:-$HOME/scia-scenario}"
SCENARIO_RUNS="$SCENARIO_HOME/runs"
SCENARIO_HOST=mastodon.localhost
# 流し込むアカウントのパスワード。このローカルのサーバーだけのテスト用の値
SCENARIO_PASSWORD=scenario-password
SCIA_BUNDLE_ID=net.mizle.scia
DEVICE_NAME='Scia Scenario'
DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro

log() { echo "scenario: $*" >&2; }
fail() { log "$*"; exit 1; }

compose() { docker compose -f "$SCENARIO_DIR/compose.yml" "$@"; }

# スナップショットを作ったときの中身を表す値。compose.yml（Mastodonの版など）、流し込みの中身、秘密の値のどれかが変われば、作り直す
snapshot_key() {
    { cat "$SCENARIO_DIR/compose.yml" "$SCENARIO_DIR/seed/seed.rb" "$SCENARIO_HOME/env.production"; echo "$SCENARIO_PASSWORD"; } | shasum -a 256 | cut -d' ' -f1
}

# データの置き場所をスナップショットで置き換えてから動かす。前に使った人の投稿やフォローを持ち越さないため、毎回置き換える
restore_server() {
    log "Mastodonのデータをスナップショットに戻す"
    compose down --remove-orphans
    rm -rf "$SCENARIO_HOME/data"
    mkdir -p "$SCENARIO_HOME/data"
    tar -xf "$SCENARIO_HOME/snapshot/data.tar" -C "$SCENARIO_HOME/data"
    compose up -d --wait
}

device_udid() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"] == name and device.get("isAvailable", True):
            print(device["udid"])
' "$DEVICE_NAME"
}

device_state() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["udid"] == sys.argv[1]:
            print(device["state"])
' "$1"
}

boot_device() {
    [ "$(device_state "$1")" = Booted ] || xcrun simctl boot "$1"
    xcrun simctl bootstatus "$1" -b >/dev/null
}

shutdown_device() {
    [ "$(device_state "$1")" = Shutdown ] || xcrun simctl shutdown "$1"
}

# Sciaを消して入れ直す。Sciaを消してもKeychainのログイン情報は残り、Sciaは起動するとKeychainのログイン情報をすべて読む（CredentialStore.loadAll）。
# そのため、設定やキャッシュは初めての状態で、ログインした状態から始まる
reinstall_app() {
    local udid="$1" app="$2"
    if xcrun simctl get_app_container "$udid" "$SCIA_BUNDLE_ID" >/dev/null 2>&1; then
        xcrun simctl uninstall "$udid" "$SCIA_BUNDLE_ID"
    fi
    xcrun simctl install "$udid" "$app"
}

# Sciaを入れ直して起動し、ログインした状態でホームにyouの投稿が出れば0、ログイン画面が出たか、30秒で投稿が出なければ1を返す。
# 人として触った人がログアウトすると、SciaがKeychainのログイン情報を消すので、次の人の前にこれで確かめる
app_logged_in() {
    local udid="$1" app="$2" deadline=$((SECONDS + 30)) tree
    reinstall_app "$udid" "$app"
    xcrun simctl launch "$udid" "$SCIA_BUNDLE_ID" >/dev/null
    while [ $SECONDS -lt $deadline ]; do
        tree="$(axe describe-ui --udid "$udid" 2>/dev/null || true)"
        if python3 -I "$SCENARIO_DIR/ui.py" contains はじめての投稿です <<< "$tree"; then
            xcrun simctl terminate "$udid" "$SCIA_BUNDLE_ID"
            return 0
        fi
        python3 -I "$SCENARIO_DIR/ui.py" has mastodon.social TextField <<< "$tree" && break
        sleep 1
    done
    xcrun simctl terminate "$udid" "$SCIA_BUNDLE_ID"
    return 1
}

# ハードウェアキーボードがつながっていると、画面にキーボードが出ず、ログインで押すキーボードの上の「次へ」もない。毎回外す
use_software_keyboard() {
    swift "$SCENARIO_DIR/../sim-keyboard.swift" "$1" software >/dev/null
}

# 画面に、AXLabelと種類が一致する要素が出るまで待つ。Sciaの外の画面（サインインのダイアログやログインのページ）は全体の木に出ないので、wait_pointで待つ
wait_label() {
    local udid="$1" label="$2" kind="${3:-}" deadline=$((SECONDS + 30))
    until axe describe-ui --udid "$udid" 2>/dev/null | python3 -I "$SCENARIO_DIR/ui.py" has "$label" $kind; do
        [ $SECONDS -lt $deadline ] || fail "30秒待っても「${label}」が出なかった"
        sleep 1
    done
}

wait_point() {
    local udid="$1" x="$2" y="$3" label="$4" deadline=$((SECONDS + 30))
    until [ "$(axe describe-ui --point "$x,$y" --udid "$udid" 2>/dev/null | python3 -I "$SCENARIO_DIR/ui.py" label)" = "$label" ]; do
        [ $SECONDS -lt $deadline ] || fail "30秒待っても($x,$y)に「${label}」が出なかった"
        sleep 1
    done
}

# 要素が出るまで待って押し、消えなければ2秒おいて押し直す。30秒たっても消えなければ止める
# 画面の木を読めなかったときは、消えたとみなさずに読み直す。読めた木に要素がないときだけ抜ける
tap_label_until_gone() {
    local udid="$1" label="$2" kind="$3" deadline=$((SECONDS + 30)) tree
    wait_label "$udid" "$label" "$kind"
    while true; do
        [ $SECONDS -lt $deadline ] || fail "30秒押しても「${label}」が消えなかった"
        if ! tree="$(axe describe-ui --udid "$udid" 2>/dev/null)" || ! python3 -I -c 'import json, sys; json.load(sys.stdin)' <<< "$tree" 2>/dev/null; then
            sleep 1
            continue
        fi
        python3 -I "$SCENARIO_DIR/ui.py" has "$label" "$kind" <<< "$tree" || return 0
        axe tap --label "$label" --element-type "$kind" --tap-style physical --udid "$udid" >/dev/null || true
        sleep 2
    done
}

# AXeの既定のタップはSciaのボタンにもキーボードにも届かなかった。押し下げと離しを送るphysicalにする
tap_point() {
    axe tap -x "$2" -y "$3" --tap-style physical --udid "$1" >/dev/null
}
