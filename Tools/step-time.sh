#!/bin/sh
# make check、make testの中の段階にかかった時間を、SCIA_STEP_LOGのファイルに1行ずつ足す。SCIA_STEP_LOGがなければ何も書かない。
# Tools/merge-queue.shがSCIA_STEP_LOGを渡し、走り終えたらtiming.logへ移す。行は「始めたUNIX時刻 段階 秒 結果」のタブ区切りで、結果はokか終了コード。
# 走らせた場所は「place 場所」の行で書く。そのあとの行は、次の「place」の行まで、その場所で走ったもの。
# 使い方:
#   Tools/step-time.sh run <段階> <コマンド>...           コマンドを走らせて記録し、コマンドの終了コードで終わる
#   Tools/step-time.sh record <段階> <始めたUNIX時刻> <終了コード> [<終えたUNIX時刻>]   後ろで走らせたものなど、走らせ終えた段階を記録する。終えた時刻を省くと今にする
#   Tools/step-time.sh place <場所>                        走らせた場所を記録する
set -u

record() {
    [ -n "${SCIA_STEP_LOG:-}" ] || return 0
    result=$3
    [ "$result" = 0 ] && result=ok
    printf '%s\t%s\t%s\t%s\n' "$2" "$1" "$(( ${4:-$(date +%s)} - $2 ))" "$result" >> "$SCIA_STEP_LOG"
}

case "${1:-}" in
    run)
        name=$2
        shift 2
        start=$(date +%s)
        # 止める合図で先に終わると、待っている親が、子が後始末を終える前に端末や枠を返すので、子が終わるまで待つ。
        # 合図を無視（trap ''）にすると子も受け継いで止まらなくなるので、何もしない処理を置く
        trap ':' HUP INT TERM
        "$@"
        status=$?
        record "$name" "$start" "$status"
        exit "$status"
        ;;
    record)
        record "$2" "$3" "$4" "${5:-}"
        ;;
    place)
        [ -z "${SCIA_STEP_LOG:-}" ] || printf 'place\t%s\n' "$2" >> "$SCIA_STEP_LOG"
        ;;
    *)
        echo "使い方: Tools/step-time.sh run <段階> <コマンド>... | record <段階> <始めたUNIX時刻> <終了コード> | place <場所>" >&2
        exit 1
        ;;
esac
