#!/bin/bash
# 1人分を始める前に、Mastodonと端末を、前の人の跡がない状態に戻す。setup.shを済ませてから使う。
# - Mastodonのデータをスナップショットに戻す
# - 端末を起動し、Sciaを消し、Keychainを消してから、渡したSciaを入れる。Sciaを消してもKeychainのログイン情報は残るため、Keychainも消す
#   Keychainを消しても、信頼している認証局は残る（端末の信頼ストアは別にある）
# 端末は起動したままにする。1人分が終わったら止める。
# 使い方: Tools/scenario/reset.sh <Scia.appのパス>
set -euo pipefail
source "$(dirname "$0")/common.sh"

app="${1:?使い方: Tools/scenario/reset.sh <Scia.appのパス>}"
[ -d "$app" ] || fail "$app がない"
udid="$(device_udid)"
[ -n "$udid" ] || fail "$DEVICE_NAME がない。先にsetup.shを走らせる"

restore_server
boot_device "$udid"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
if xcrun simctl get_app_container "$udid" "$bundle_id" >/dev/null 2>&1; then
    xcrun simctl uninstall "$udid" "$bundle_id"
fi
xcrun simctl keychain "$udid" reset
xcrun simctl install "$udid" "$app"
log "始められる: $DEVICE_NAME ($udid)"
