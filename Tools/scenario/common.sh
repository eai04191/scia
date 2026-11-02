# setup.shとreset.shが読み込む、シナリオの置き場所と共通の手順。
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 証明書、Mastodonの秘密の値、データ、スナップショットは、リポジトリの外に置く。worktreeを消しても残し、どのworktreeからも同じものを使う
export SCENARIO_HOME="${SCIA_SCENARIO_HOME:-$HOME/.scia-scenario}"
SCENARIO_HOST=mastodon.localhost
DEVICE_NAME='Scia Scenario'
DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro

log() { echo "scenario: $*" >&2; }
fail() { log "$*"; exit 1; }

compose() { docker compose -f "$SCENARIO_DIR/compose.yml" "$@"; }

# スナップショットを作ったときの中身を表す値。compose.yml（Mastodonの版など）、流し込みの中身、秘密の値のどれかが変われば、作り直す
snapshot_key() {
    cat "$SCENARIO_DIR/compose.yml" "$SCENARIO_DIR/seed/seed.rb" "$SCENARIO_HOME/env.production" | shasum -a 256 | cut -d' ' -f1
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
