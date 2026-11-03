#!/bin/bash
# 人が読む文書（FEATURES.mdとREADME.md）を、人が読んで承認した中身でなければmainに入れさせない。Tools/git-hooks/reference-transactionとTools/merge-queue.shがこれで調べる。
# 覚えるのはcommitではなくファイルの中身（blob）。rebaseで中身が変わらなければ、承認は引き継がれる。
# 覚えた中身は、worktreeどうしで共有する.gitの共通ディレクトリのscia-check/human-review/に、「パス-blobのハッシュ」を名前にした空のファイルで置く。消したファイルはハッシュの代わりにdeletedと書く。
# approveは、承認の入力を/dev/ttyから読む。端末を持たないagentのBashでは/dev/ttyを開けないので、承認できない。
# scriptコマンドで疑似端末を作って入力を流し込めば、agentでも承認できてしまう。仕組みでは防げないので、AGENTS.mdの決まりで止めている。
# 使い方:
#   Tools/human-review.sh approve <commit> [<base>]  <base>（省略時はmain）との差分を見せ、承認したら<commit>の中身を覚える。ユーザーが自分の端末で走らせる
#   Tools/human-review.sh missing <commit> [<base>]  <base>（省略時はmain）と中身が違い、まだ承認していないファイルを1行ずつ出す
set -euo pipefail

FILES="FEATURES.md README.md"

review_dir() {
    echo "$(git rev-parse --git-common-dir)/scia-check/human-review"
}

# <commit>の<path>の中身を表す名前。ファイルがなければdeletedにする
content_key() {
    local blob
    blob=$(git rev-parse -q --verify "$1:$2" || true)
    echo "$2-${blob:-deleted}"
}

changed_files() {
    local commit=$1 base=$2 path
    for path in $FILES; do
        [[ "$(content_key "$commit" "$path")" == "$(content_key "$base" "$path")" ]] || echo "$path"
    done
}

unapproved_files() {
    local commit=$1 base=$2 path
    for path in $(changed_files "$commit" "$base"); do
        [[ -e "$(review_dir)/$(content_key "$commit" "$path")" ]] || echo "$path"
    done
}

case "${1:-}" in
    approve)
        commit=$(git rev-parse --verify "${2:?commitを渡す}^{commit}")
        base=$(git rev-parse --verify "${3:-main}^{commit}")
        files=$(unapproved_files "$commit" "$base")
        if [[ -z "$files" ]]; then
            echo "$(git log -1 --format='%h' "$commit") の $FILES は、承認済みか、$(git log -1 --format='%h' "$base")と同じです"
            exit 0
        fi
        # 承認の入力は端末から読む。標準入力から読むと、agentがパイプで流し込めるため
        if ! exec 3<>/dev/tty; then
            echo "error: 端末を開けませんでした。承認は、ユーザーが自分の端末で走らせてください" >&2
            exit 1
        fi
        # shellcheck disable=SC2086
        git --no-pager diff --color=always "$base" "$commit" -- $files >&3
        printf '%s の %s の変更を承認しますか？ [y/N] ' "$(git log -1 --format='%h %s' "$commit")" "$(echo $files)" >&3
        read -r answer <&3
        if [[ "$answer" != y && "$answer" != Y ]]; then
            echo "承認しませんでした"
            exit 1
        fi
        mkdir -p "$(review_dir)"
        for path in $files; do
            touch "$(review_dir)/$(content_key "$commit" "$path")"
        done
        echo "承認しました"
        ;;
    missing)
        commit=$(git rev-parse --verify "${2:?commitを渡す}^{commit}")
        base=$(git rev-parse --verify "${3:-main}^{commit}")
        unapproved_files "$commit" "$base"
        ;;
    *)
        echo "使い方: Tools/human-review.sh approve <commit> [<base>] | missing <commit> [<base>]" >&2
        exit 1
        ;;
esac
