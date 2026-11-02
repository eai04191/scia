#!/bin/bash
# 1人分を始める前に、Mastodonと端末を、前の人の跡がない状態に戻す。
# - Mastodonのデータをスナップショットに戻す
# - 端末を起動し、Sciaを消してから、渡したSciaを入れる。Keychainは消さない。setup.shがスナップショットを作るときにログインしたyouの
#   ログイン情報が残り、そのアクセストークンはスナップショットの中にあるので、Sciaはログインした状態の、初めての設定とキャッシュで始まる
# - 前の人がログアウトしてログイン情報が消えていたり、setup.shを済ませていなかったりしたら、setup.shで揃えてから戻す
# 端末は起動したままにし、Sciaは起動しない。1人分が終わったら止める。
# 使い方: Tools/scenario/reset.sh <Scia.appのパス>
set -euo pipefail
source "$(dirname "$0")/common.sh"

app="${1:?使い方: Tools/scenario/reset.sh <Scia.appのパス>}"
[ -d "$app" ] || fail "$app がない"
udid="$(device_udid)"

if [ -z "$udid" ] || [ "$(cat "$SCENARIO_HOME/snapshot/udid" 2>/dev/null)" != "$udid" ]; then
    "$SCENARIO_DIR/setup.sh" "$app"
    udid="$(device_udid)"
fi
restore_server
boot_device "$udid"
use_software_keyboard "$udid"
if ! app_logged_in "$udid" "$app"; then
    log "ログインした状態で始まらなかったので、setup.shで揃える"
    "$SCENARIO_DIR/setup.sh" "$app"
    restore_server
    boot_device "$udid"
    app_logged_in "$udid" "$app" || fail "setup.shのあとも、Sciaがログインした状態で始まらなかった"
fi
# app_logged_inで起動したSciaは、ホームを読み込んで設定やキャッシュを作っている。初めての状態で渡すため、もう一度入れ直す
reinstall_app "$udid" "$app"
log "始められる: $DEVICE_NAME ($udid)"
