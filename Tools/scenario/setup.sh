#!/bin/bash
# シナリオの準備をする。何度走らせても、最後は同じ状態になる。
# - 外へ出ないMastodonが、流し込んだ直後の中身で動いている
# - 専用の端末（Scia Scenario）があり、使わないサービスを止め、キーボードを英語だけにし、シナリオの認証局を信頼している
# - 端末のKeychainに、スナップショットの中のyouのログイン情報がある。ログインのページやサインインのダイアログはSciaの外にあり、
#   人として触らせても直せないので、スナップショットを作るときにAXeで1回だけログインしておく
# 足りないものだけを作り、Mastodonのデータは毎回スナップショットで置き換える。最後に、端末の中からhttpsで届くかと、
# 入れ直したSciaがログインした状態でホームを出すかを確かめ、端末を止める。
# 使い方: Tools/scenario/setup.sh <Scia.appのパス>
set -euo pipefail
source "$(dirname "$0")/common.sh"

app="${1:?使い方: Tools/scenario/setup.sh <Scia.appのパス>}"
[ -d "$app" ] || fail "$app がない"
for command in docker mkcert simslim xcrun shasum sqlite3 axe; do
    command -v "$command" >/dev/null || fail "$command が見つからない"
done
docker info >/dev/null 2>&1 || fail "Dockerにつながらない。OrbStackかDocker Desktopを起動する"

ensure_certs() {
    mkdir -p "$SCENARIO_HOME/ca" "$SCENARIO_HOME/certs"
    [ -f "$SCENARIO_HOME/certs/cert.pem" ] && return
    log "認証局と証明書を作る"
    # CAROOTを分けて、Macのキーチェーンには入れない（mkcert -installは使わない）
    CAROOT="$SCENARIO_HOME/ca" mkcert -cert-file "$SCENARIO_HOME/certs/cert.pem" -key-file "$SCENARIO_HOME/certs/key.pem" "$SCENARIO_HOST"
}

ensure_env() {
    local env="$SCENARIO_HOME/env.production"
    [ -f "$env" ] && return
    log "Mastodonの秘密の値を作る"
    cat > "$env.tmp" <<EOF
LOCAL_DOMAIN=$SCENARIO_HOST
RAILS_ENV=production
NODE_ENV=production
REDIS_HOST=redis
REDIS_PORT=6379
DB_HOST=db
DB_USER=postgres
DB_NAME=mastodon_production
DB_PASS=
DB_PORT=5432
ES_ENABLED=false
SMTP_DELIVERY_METHOD=test
SMTP_FROM_ADDRESS=notifications@$SCENARIO_HOST
SECRET_KEY_BASE=$(openssl rand -hex 64)
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 32)
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 32)
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 32)
EOF
    # VAPIDの鍵はMastodonのrakeで作る。ほかの値が入った環境で起動する必要があるので、いったん置いてから足す
    mv "$env.tmp" "$env"
    compose run --rm --no-deps -T web bundle exec rake mastodon:webpush:generate_vapid_key | grep '^VAPID_' > "$env.vapid" \
        || { rm -f "$env" "$env.vapid"; fail "VAPIDの鍵を作れなかった"; }
    cat "$env.vapid" >> "$env"
    rm "$env.vapid"
}

ensure_snapshot() {
    local udid="$1" key
    key="$(snapshot_key)"
    # 投稿の日時と投票の締め切り（7日）は、流し込んだときの日時で固まる。6日を超えたスナップショットは、投票が締め切り間近か締め切り済みで始まるので作り直す
    # ログイン情報は端末のKeychainにあり、そのアクセストークンはスナップショットの中にある。端末を作り直したら、ログインし直してスナップショットも作り直す
    if [ -f "$SCENARIO_HOME/snapshot/key" ] && [ "$(cat "$SCENARIO_HOME/snapshot/key")" = "$key" ] \
        && [ -z "$(find "$SCENARIO_HOME/snapshot/key" -mtime +6)" ] \
        && [ "$(cat "$SCENARIO_HOME/snapshot/udid" 2>/dev/null)" = "$udid" ]; then
        return
    fi
    log "空のデータから立てて流し込み、スナップショットを作る"
    compose down --remove-orphans
    rm -rf "$SCENARIO_HOME/data" "$SCENARIO_HOME/snapshot"
    mkdir -p "$SCENARIO_HOME/data/postgres" "$SCENARIO_HOME/data/redis" "$SCENARIO_HOME/data/system"
    compose up -d --wait db redis
    compose run --rm -T web bundle exec rails db:setup
    compose up -d --wait sidekiq
    compose run --rm -T -e SCENARIO_PASSWORD="$SCENARIO_PASSWORD" web bin/rails runner /seed/seed.rb
    compose up -d --wait
    login_on_device "$udid"
    # 止めるとRedisが中身をファイルに書くので、止めてから固める
    compose down
    mkdir -p "$SCENARIO_HOME/snapshot"
    tar -cf "$SCENARIO_HOME/snapshot/data.tar" -C "$SCENARIO_HOME/data" .
    echo "$udid" > "$SCENARIO_HOME/snapshot/udid"
    echo "$key" > "$SCENARIO_HOME/snapshot/key"
}

# 前のログイン情報を消し、入れ直したSciaでyouとしてログインする。
# Mastodonのログインのページとサインインのダイアログは、AXeの全体の木に出ないので、位置で要素の名前を確かめてから押す。位置はiPhone 16 Proの画面のもの
login_on_device() {
    local udid="$1"
    log "端末のSciaでyouとしてログインする"
    boot_device "$udid"
    xcrun simctl keychain "$udid" reset
    reinstall_app "$udid" "$app"
    xcrun simctl launch "$udid" "$SCIA_BUNDLE_ID" >/dev/null
    wait_label "$udid" stellaria.network TextField
    axe tap --value stellaria.network --element-type TextField --tap-style physical --udid "$udid" >/dev/null
    axe type "$SCENARIO_HOST" --udid "$udid" >/dev/null
    axe tap --label ログイン --element-type PopUpButton --tap-style physical --udid "$udid" >/dev/null
    wait_label "$udid" 続ける Button
    axe tap --label 続ける --element-type Button --tap-style physical --udid "$udid" >/dev/null
    wait_point "$udid" 201 544 メールアドレス
    tap_point "$udid" 201 544
    # キーボードが出るとページが動き、パスワードの欄の位置が変わる。Tabキーでは次の欄に移らなかったので、キーボードの上の「次へ」で移る
    # Returnキーでは送られないことがあったので、動いたあとの位置にある「ログイン」のボタンを押す
    axe type "you@$SCENARIO_HOST" --udid "$udid" >/dev/null
    wait_point "$udid" 93 512 次へ
    tap_point "$udid" 93 512
    axe type "$SCENARIO_PASSWORD" --udid "$udid" >/dev/null
    wait_point "$udid" 201 386 ログイン
    tap_point "$udid" 201 386
    wait_point "$udid" 201 593 今はしない
    tap_point "$udid" 201 593
    wait_point "$udid" 103 594 承認
    tap_point "$udid" 103 594
    wait_label "$udid" ホーム Heading
    xcrun simctl terminate "$udid" "$SCIA_BUNDLE_ID"
}

ensure_keyboard() {
    local udid="$1"
    # 日本語のキーボードでは、AXeで打った文字が変換中のまま残ったり、遅れて二重に入ったりした。英語のソフトウェアキーボードだけにする
    # ハードウェアキーボードはつながない。つなぐと画面にキーボードが出ず、投稿欄とキーボードが重なる見え方を確かめられない
    boot_device "$udid"
    use_software_keyboard "$udid"
    [ "$(xcrun simctl spawn "$udid" defaults read -g AppleKeyboards 2>/dev/null | tr -d ' \n')" = '("en_US@sw=QWERTY;hw=Automatic")' ] && return
    log "キーボードを英語だけにする"
    xcrun simctl spawn "$udid" defaults write -g AppleKeyboards -array 'en_US@sw=QWERTY;hw=Automatic'
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences KeyboardsCurrentAndNext -array 'en_US@sw=QWERTY;hw=Automatic'
    shutdown_device "$udid"
    boot_device "$udid"
}

ensure_device() {
    local udid runtime
    udid="$(device_udid)"
    if [ -z "$udid" ]; then
        runtime="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
runtimes.sort(key=lambda r: [int(part) for part in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")
')"
        [ -n "$runtime" ] || fail "使えるiOSのランタイムがない"
        log "端末を作る: $DEVICE_NAME ($runtime)"
        udid="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$runtime")"
    fi
    echo "$udid"
}

ensure_slim() {
    local udid="$1"
    # 止めた端末では読めない。「160/168 managed launchd labels disabled」の形で出て、1つでも止めていれば入れてある
    boot_device "$udid"
    if simslim status "$udid" | grep -qE '^[^:]+: [1-9][0-9]*/[0-9]+ managed launchd labels disabled'; then
        return
    fi
    log "使わないサービスを止める（写真は残す）"
    simslim on "$udid" --except photos
}

root_cert_trusted() {
    local udid="$1" store fingerprint
    store="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/private/var/protected/trustd/private/TrustStore.sqlite3"
    [ -f "$store" ] || return 1
    fingerprint="$(openssl x509 -in "$SCENARIO_HOME/ca/rootCA.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)"
    [ "$(sqlite3 "file:$store?mode=ro" "select count(*) from tsettings where hex(sha256) = '$fingerprint'")" = 1 ]
}

ensure_root_cert() {
    local udid="$1"
    root_cert_trusted "$udid" && return
    log "端末にシナリオの認証局を入れる"
    boot_device "$udid"
    xcrun simctl keychain "$udid" add-root-cert "$SCENARIO_HOME/ca/rootCA.pem"
    # 作った直後の端末で入れた証明書が、再起動で消えたことがあった。起動し直しても残っているかを確かめる
    shutdown_device "$udid"
    boot_device "$udid"
    root_cert_trusted "$udid" || fail "入れた認証局が、端末を起動し直すと消えた"
}

verify_reach() {
    local udid="$1" probe="$SCENARIO_HOME/bin/reach"
    if [ ! -x "$probe" ] || [ "$SCENARIO_DIR/reach.swift" -nt "$probe" ]; then
        log "確かめのプログラムをビルドする"
        mkdir -p "$SCENARIO_HOME/bin"
        xcrun -sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios$(xcrun --sdk iphonesimulator --show-sdk-version)-simulator" -o "$probe" "$SCENARIO_DIR/reach.swift"
    fi
    boot_device "$udid"
    log "端末の中から https://$SCENARIO_HOST/api/v2/instance に届くか確かめる"
    xcrun simctl spawn "$udid" "$probe" "https://$SCENARIO_HOST/api/v2/instance" >/dev/null || fail "端末の中からMastodonに届かなかった"
}

verify_logged_in() {
    local udid="$1"
    log "入れ直したSciaが、ログインした状態でホームにyouの投稿を出すか確かめる"
    app_logged_in "$udid" "$app" && return
    # 人として触った人がログアウトすると、Keychainのログイン情報が消える。ログインし直して、そのトークンを含むスナップショットを作り直す
    log "ログインした状態で始まらなかったので、ログインし直してスナップショットを作り直す"
    rm -f "$SCENARIO_HOME/snapshot/key"
    ensure_snapshot "$udid"
    restore_server
    app_logged_in "$udid" "$app" || fail "ログインし直しても、Sciaがログインした状態で始まらなかった"
}

ensure_certs
ensure_env
udid="$(ensure_device)"
ensure_slim "$udid"
ensure_keyboard "$udid"
ensure_root_cert "$udid"
ensure_snapshot "$udid"
restore_server
verify_reach "$udid"
verify_logged_in "$udid"
shutdown_device "$udid"
log "準備できた: $DEVICE_NAME ($udid)、https://$SCENARIO_HOST"
